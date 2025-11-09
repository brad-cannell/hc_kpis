# R/data_03_load_appointments.R
# Load/update the `person_appointments` table in db/faculty.duckdb
# from data/faculty_appointments.csv

library(DBI)
library(duckdb)
library(readr)
library(dplyr)
library(uuid)

# --------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------
db_path   <- file.path("db", "faculty.duckdb")
data_path <- file.path("data", "faculty_appointments.csv")

if (!file.exists(db_path)) {
  stop("Database not found at ", db_path,
       ". Did you run R/data_01_duckdb_schema.R first?")
}

if (!file.exists(data_path)) {
  stop("Input CSV not found at ", data_path,
       ". Please create data/faculty_appointments.csv before running this script.")
}

# --------------------------------------------------------------------
# Connect to DuckDB
# --------------------------------------------------------------------
con <- dbConnect(duckdb::duckdb(dbdir = db_path))

# Quick check: ensure tables exist
tables <- dbGetQuery(con, "SHOW TABLES;")$name
if (!"people" %in% tables) {
  dbDisconnect(con)
  stop("Table 'people' not found. Run data_01_duckdb_schema.R and data_02_load_people.R first.")
}
if (!"person_appointments" %in% tables) {
  dbDisconnect(con)
  stop("Table 'person_appointments' not found. Run data_01_duckdb_schema.R first.")
}

# --------------------------------------------------------------------
# Read and clean CSV
# --------------------------------------------------------------------
raw_appts <- readr::read_csv(data_path, show_col_types = FALSE)

expected_cols <- c(
  "appt_id", "person_id", "unit_code", "rank", "track",
  "fte_share", "status", "valid_from", "valid_to", "source", "notes"
)
missing_cols <- setdiff(expected_cols, names(raw_appts))
if (length(missing_cols) > 0) {
  dbDisconnect(con)
  stop("Missing expected column(s) in faculty_appointments.csv: ",
       paste(missing_cols, collapse = ", "))
}

appts_clean <- raw_appts %>%
  mutate(
    # Trim text fields
    person_id  = trimws(person_id),
    unit_code  = toupper(trimws(unit_code)),
    rank       = trimws(rank),
    track      = trimws(track),
    status     = trimws(status),
    source     = trimws(source),
    notes      = trimws(notes),
    
    # Numeric & dates
    fte_share  = as.numeric(fte_share),
    valid_from = as.Date(valid_from),
    valid_to   = ifelse(
      is.na(valid_to) | valid_to == "",
      NA, valid_to
    ),
    valid_to   = as.Date(valid_to),
    
    # Generate UUIDs for missing appt_id
    appt_id    = ifelse(
      is.na(appt_id) | appt_id == "",
      UUIDgenerate(n = n()),
      appt_id
    )
  )

# Basic validation
if (any(is.na(appts_clean$person_id) | appts_clean$person_id == "")) {
  dbDisconnect(con)
  stop("Some rows have missing person_id. Please fix faculty_appointments.csv.")
}
if (any(is.na(appts_clean$unit_code) | appts_clean$unit_code == "")) {
  dbDisconnect(con)
  stop("Some rows have missing unit_code. Please fix faculty_appointments.csv.")
}
if (any(is.na(appts_clean$valid_from))) {
  dbDisconnect(con)
  stop("Some rows have missing valid_from. Please fix faculty_appointments.csv.")
}

# Check that all person_id values exist in people
known_ids <- dbGetQuery(con, "SELECT person_id FROM people;")$person_id
unknown_ids <- setdiff(unique(appts_clean$person_id), known_ids)
if (length(unknown_ids) > 0) {
  dbDisconnect(con)
  stop(
    "Some person_id values in faculty_appointments.csv do not exist in `people`.\n",
    "Examples: ", paste(head(unknown_ids, 5), collapse = ", "), "\n",
    "Load people first or correct the IDs."
  )
}

# --------------------------------------------------------------------
# Upsert into `person_appointments`
#
# Strategy:
#   - Create TEMP staging table
#   - Delete existing rows with same appt_id
#   - Insert cleaned rows
# --------------------------------------------------------------------

dbExecute(con, "DROP TABLE IF EXISTS stg_person_appointments;")
dbExecute(con, "
  CREATE TEMP TABLE stg_person_appointments AS
  SELECT * FROM person_appointments WHERE 1=0;
")

dbWriteTable(con, "stg_person_appointments", appts_clean, append = TRUE)

dbExecute(con, "
  DELETE FROM person_appointments
  WHERE appt_id IN (SELECT appt_id FROM stg_person_appointments);
")

dbExecute(con, "
  INSERT INTO person_appointments
  SELECT * FROM stg_person_appointments;
")

# --------------------------------------------------------------------
# Sanity checks / preview
# --------------------------------------------------------------------
n_appts <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM person_appointments")$n

preview <- dbGetQuery(con, "
  SELECT appt_id, person_id, unit_code, rank, track, fte_share,
         status, valid_from, valid_to
  FROM person_appointments
  ORDER BY valid_from, unit_code
  LIMIT 10;
")

dbDisconnect(con)

cat("Successfully loaded/updated person_appointments.\n")
cat("Total rows in person_appointments table:", n_appts, "\n\n")
print(preview)

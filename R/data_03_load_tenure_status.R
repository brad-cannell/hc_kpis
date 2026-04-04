# =============================================================================
# R/data_03_load_tenure_status.R
# Loads the `tenure_status` table from:
#   HC_KPIS/data/raw/faculty_roster_clean.csv
# Joins on first_name + last_name to get person_id from `people`.
# One row per person per unit (handles joint appointments).
# =============================================================================

library(DBI)
library(duckdb)
library(readr)
library(dplyr)
library(uuid)

# Paths -----------------------------------------------------------------------
db_path   <- file.path("db", "faculty.duckdb")
data_path <- file.path("data", "raw", "faculty_roster_clean.csv")

if (!file.exists(db_path)) stop("Database not found. Run data_01_duckdb_schema.R first.")
if (!file.exists(data_path)) stop("CSV not found at ", data_path)

# Connect ---------------------------------------------------------------------
con <- dbConnect(duckdb::duckdb(dbdir = db_path))

# Pull people table for joining -----------------------------------------------
people_db <- dbGetQuery(con, "SELECT person_id, first_name, last_name FROM people;")

# Read & clean ----------------------------------------------------------------
raw <- readr::read_csv(data_path, show_col_types = FALSE)

tenure_clean <- raw |>
  rename(first_name = given_name, last_name = family_name) |>
  mutate(
    first_name = trimws(first_name),
    last_name  = trimws(last_name),
    unit_code  = trimws(unit_code),
    unit_name  = trimws(unit_name),
    track      = trimws(track)
  ) |>
  # Join to get person_id
  left_join(people_db, by = c("first_name", "last_name")) |>
  mutate(
    tenure_id  = UUIDgenerate(n = n()),
    valid_from = Sys.Date(),   # adjust as needed
    valid_to   = as.Date(NA),
    source     = "faculty_roster_clean.csv",
    notes      = NA_character_
  ) |>
  select(tenure_id, person_id, unit_code, unit_name, track,
         valid_from, valid_to, source, notes)

# Validate --------------------------------------------------------------------
unmatched <- filter(tenure_clean, is.na(person_id))
if (nrow(unmatched) > 0) {
  dbDisconnect(con)
  stop(
    nrow(unmatched), " row(s) could not be matched to a person_id.\n",
    "Check for name mismatches:\n",
    paste(unmatched$first_name, unmatched$last_name, collapse = "\n")
  )
}

valid_tracks <- c("Tenured", "Tenure-Track", "Professional Practice")
bad_tracks <- filter(tenure_clean, !track %in% valid_tracks)
if (nrow(bad_tracks) > 0) {
  dbDisconnect(con)
  stop(
    "Invalid track value(s): ",
    paste(unique(bad_tracks$track), collapse = ", "),
    "\nAllowed values: ", paste(valid_tracks, collapse = ", ")
  )
}

# Upsert ----------------------------------------------------------------------
dbExecute(con, "DROP TABLE IF EXISTS stg_tenure;")
dbExecute(con, "CREATE TEMP TABLE stg_tenure AS SELECT * FROM tenure_status WHERE 1=0;")
dbWriteTable(con, "stg_tenure", tenure_clean, append = TRUE)
dbExecute(con, "DELETE FROM tenure_status WHERE tenure_id IN (SELECT tenure_id FROM stg_tenure);")
dbExecute(con, "INSERT INTO tenure_status SELECT * FROM stg_tenure;")

# Check -----------------------------------------------------------------------
n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM tenure_status")$n
cat("Rows in tenure_status:", n, "\n")
print(dbGetQuery(con, "
  SELECT p.first_name, p.last_name, t.unit_code, t.track
  FROM tenure_status t
  JOIN people p ON p.person_id = t.person_id
  ORDER BY p.last_name, p.first_name
  LIMIT 10;
"))

dbDisconnect(con)
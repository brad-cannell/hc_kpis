# =============================================================================
# R/data_03_load_tenure_status.R
# Loads the `tenure_status` table from:
#   HC_KPIS/data/raw/faculty_roster_clean.csv
# Joins on first_name + last_name to get person_id from `people`.
# One row per person per unit (handles joint appointments).
# =============================================================================

suppressPackageStartupMessages(library(DBI))
suppressPackageStartupMessages(library(duckdb))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(uuid))

# Paths -----------------------------------------------------------------------
db_path   <- file.path("db", "faculty.duckdb")
data_path <- file.path("data", "raw", "faculty_roster_clean.csv")

if (!file.exists(db_path)) stop("Database not found. Run data_01_duckdb_schema.R first.")
if (!file.exists(data_path)) stop("CSV not found at ", data_path)

# Connection helper ------------------------------------------------------------
connect_duckdb_safe <- function(path) {
  tryCatch(
    DBI::dbConnect(duckdb::duckdb(dbdir = path)),
    error = function(e) {
      msg <- conditionMessage(e)
      if (grepl("Could not set lock on file|Conflicting lock is held", msg)) {
        stop(
          paste0(
            "DuckDB file is locked by another process.\n",
            "Close any open DB viewers/extensions using ", path, " and try again.\n",
            "If needed, restart your IDE/R session to clear stale locks.\n\n",
            "Original error: ", msg
          ),
          call. = FALSE
        )
      }
      stop(e)
    }
  )
}

# Connect ---------------------------------------------------------------------
con <- connect_duckdb_safe(db_path)
load_date <- Sys.Date()

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
    valid_from = load_date,   # adjust as needed
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

# Synchronize current statuses ------------------------------------------------
# The roster is a complete current-state snapshot. Preserve an unchanged
# person/unit/track row so a routine reload does not manufacture history; close
# a previous row only when its current value is absent from the new snapshot.
# Same-day corrections cannot have a meaningful date range, so replace the
# original same-day row rather than trying to close it one day before it began.
dbExecute(con, "DROP TABLE IF EXISTS stg_tenure;")
dbExecute(con, "CREATE TEMP TABLE stg_tenure AS SELECT * FROM tenure_status WHERE 1=0;")
dbWriteTable(con, "stg_tenure", tenure_clean, append = TRUE)
dbExecute(con, "
  DELETE FROM tenure_status
  WHERE valid_to IS NULL
    AND valid_from = CAST(? AS DATE)
    AND source = 'faculty_roster_clean.csv'
    AND NOT EXISTS (
      SELECT 1
      FROM stg_tenure AS s
      WHERE s.person_id = tenure_status.person_id
        AND s.unit_code = tenure_status.unit_code
        AND s.track = tenure_status.track
        AND s.source = tenure_status.source
    );
", params = list(load_date))
dbExecute(con, "
  UPDATE tenure_status AS t
  SET valid_to = CAST(? AS DATE) - INTERVAL 1 DAY
  WHERE t.valid_to IS NULL
    AND t.valid_from < CAST(? AS DATE)
    AND t.source = 'faculty_roster_clean.csv'
    AND NOT EXISTS (
      SELECT 1
      FROM stg_tenure AS s
      WHERE s.person_id = t.person_id
        AND s.unit_code = t.unit_code
        AND s.track = t.track
        AND s.source = t.source
    );
", params = list(load_date, load_date))
dbExecute(con, "
  INSERT INTO tenure_status
  SELECT s.*
  FROM stg_tenure AS s
  WHERE NOT EXISTS (
    SELECT 1
    FROM tenure_status AS t
    WHERE t.person_id = s.person_id
      AND t.unit_code = s.unit_code
      AND t.track = s.track
      AND t.valid_to IS NULL
      AND t.source = s.source
  );
")

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

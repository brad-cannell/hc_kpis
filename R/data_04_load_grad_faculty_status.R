# =============================================================================
# R/data_04_load_grad_faculty_status.R
# Loads the `graduate_faculty_status` table from:
#   HC_KPIS/data/raw/faculty_roster_clean.csv
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

# Pull people table for joining -----------------------------------------------
people_db <- dbGetQuery(con, "SELECT person_id, first_name, last_name FROM people;")

# Read & clean ----------------------------------------------------------------
raw <- readr::read_csv(data_path, show_col_types = FALSE)

grad_clean <- raw |>
  rename(first_name = given_name, last_name = family_name) |>
  mutate(
    first_name          = trimws(first_name),
    last_name           = trimws(last_name),
    is_graduate_faculty = as.logical(is_graduate_faculty)
  ) |>
  left_join(people_db, by = c("first_name", "last_name")) |>
  # One row per person (is_grad_faculty doesn't vary by unit)
  distinct(person_id, is_graduate_faculty) |>
  mutate(
    grad_id    = UUIDgenerate(n = n()),
    valid_from = Sys.Date(),   # adjust as needed
    valid_to   = as.Date(NA),
    source     = "faculty_roster_clean.csv",
    notes      = NA_character_
  ) |>
  select(grad_id, person_id, is_graduate_faculty,
         valid_from, valid_to, source, notes)

# Validate --------------------------------------------------------------------
unmatched <- filter(grad_clean, is.na(person_id))
if (nrow(unmatched) > 0) {
  dbDisconnect(con)
  stop(nrow(unmatched), " row(s) could not be matched to a person_id.")
}

if (any(is.na(grad_clean$is_graduate_faculty))) {
  dbDisconnect(con)
  stop("Some rows have missing is_graduate_faculty. Check the CSV.")
}

# Upsert ----------------------------------------------------------------------
dbExecute(con, "DROP TABLE IF EXISTS stg_grad;")
dbExecute(con, "CREATE TEMP TABLE stg_grad AS SELECT * FROM graduate_faculty_status WHERE 1=0;")
dbWriteTable(con, "stg_grad", grad_clean, append = TRUE)
dbExecute(con, "DELETE FROM graduate_faculty_status WHERE grad_id IN (SELECT grad_id FROM stg_grad);")
dbExecute(con, "INSERT INTO graduate_faculty_status SELECT * FROM stg_grad;")

# Check -----------------------------------------------------------------------
n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM graduate_faculty_status")$n
cat("Rows in graduate_faculty_status:", n, "\n")
print(dbGetQuery(con, "
  SELECT p.first_name, p.last_name, g.is_graduate_faculty
  FROM graduate_faculty_status g
  JOIN people p ON p.person_id = g.person_id
  ORDER BY p.last_name, p.first_name
  LIMIT 10;
"))

dbDisconnect(con)
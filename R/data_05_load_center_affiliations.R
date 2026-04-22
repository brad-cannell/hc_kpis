# =============================================================================
# R/data_05_load_center_affiliations.R
# Loads the `center_affiliations` table from:
#   HC_KPIS/data/raw/faculty_roster_clean.csv
# Supports multiple active center affiliations per person.
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

# Read raw CSV ----------------------------------------------------------------
raw <- readr::read_csv(data_path, show_col_types = FALSE)
col_names <- names(raw)

# Gracefully skip when center columns are not available yet -------------------
if (!("center_code" %in% col_names)) {
  dbDisconnect(con)
  cat("Skipped center_affiliations load: column `center_code` not found in source CSV.\n")
} else {
  # Optional columns -----------------------------------------------------------
  if (!("center_name" %in% col_names)) raw$center_name <- NA_character_
  if (!("is_primary" %in% col_names)) raw$is_primary <- FALSE

  # Read & clean --------------------------------------------------------------
  center_clean <- raw |>
    rename(first_name = given_name, last_name = family_name) |>
    mutate(
      first_name  = trimws(first_name),
      last_name   = trimws(last_name),
      center_code = trimws(center_code),
      center_name = trimws(center_name),
      is_primary  = as.logical(is_primary)
    ) |>
    filter(!is.na(center_code), center_code != "") |>
    left_join(people_db, by = c("first_name", "last_name")) |>
    distinct(person_id, center_code, center_name, is_primary) |>
    mutate(
      affiliation_id = UUIDgenerate(n = n()),
      valid_from     = Sys.Date(),
      valid_to       = as.Date(NA),
      source         = "faculty_roster_clean.csv",
      notes          = NA_character_
    ) |>
    select(
      affiliation_id, person_id, center_code, center_name, is_primary,
      valid_from, valid_to, source, notes
    )

  # Validate ------------------------------------------------------------------
  unmatched <- filter(center_clean, is.na(person_id))
  if (nrow(unmatched) > 0) {
    dbDisconnect(con)
    stop(
      nrow(unmatched), " row(s) could not be matched to a person_id.\n",
      "Check for name mismatches."
    )
  }

  if (nrow(center_clean) == 0) {
    dbDisconnect(con)
    cat("No center affiliation rows found to load.\n")
  } else {
    if (any(is.na(center_clean$is_primary))) {
      dbDisconnect(con)
      stop("Some rows have invalid `is_primary` values. Use TRUE/FALSE.")
    }

    # Upsert by business key --------------------------------------------------
    dbExecute(con, "DROP TABLE IF EXISTS stg_center_affiliations;")
    dbExecute(con, "CREATE TEMP TABLE stg_center_affiliations AS SELECT * FROM center_affiliations WHERE 1=0;")
    dbWriteTable(con, "stg_center_affiliations", center_clean, append = TRUE)

    dbExecute(con, "
      DELETE FROM center_affiliations
      WHERE (person_id, center_code, coalesce(center_name, ''), valid_from) IN (
        SELECT person_id, center_code, coalesce(center_name, ''), valid_from
        FROM stg_center_affiliations
      );
    ")

    dbExecute(con, "INSERT INTO center_affiliations SELECT * FROM stg_center_affiliations;")

    # Check -------------------------------------------------------------------
    n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM center_affiliations")$n
    cat("Rows in center_affiliations:", n, "\n")
    print(dbGetQuery(con, "
      SELECT p.first_name, p.last_name, c.center_code, c.center_name, c.is_primary
      FROM center_affiliations c
      JOIN people p ON p.person_id = c.person_id
      ORDER BY p.last_name, p.first_name, c.center_code
      LIMIT 10;
    "))

    dbDisconnect(con)
  }
}

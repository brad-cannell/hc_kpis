# =============================================================================
# R/data_01_duckdb_schema.R
# Creates the DuckDB schema from SQL files in /sql
# Run this first, before any data loading scripts.
# =============================================================================

library(DBI)
library(duckdb)
library(readr)

# Paths -----------------------------------------------------------------------
db_path <- file.path("db", "faculty.duckdb")
sql_dir <- "sql"

# Connect ---------------------------------------------------------------------
con <- dbConnect(duckdb::duckdb(dbdir = db_path))

# Find and sort SQL files (01_..., 02_..., etc.) ------------------------------
sql_files <- sort(list.files(sql_dir, pattern = "\\.sql$", full.names = TRUE))

if (length(sql_files) == 0) {
  stop("No .sql files found in 'sql/'.")
}

# Execute each file in order --------------------------------------------------
# A failed migration must leave both the schema and legacy rows intact.
tryCatch(
  DBI::dbWithTransaction(con, {
    for (f in sql_files) {
      # Do not repeat structural ALTERs on an already migrated file. Besides
      # avoiding needless index rebuilds, DuckDB 1.5.2 can crash when repeated
      # ALTER/index changes are committed after reopening an on-disk database.
      if (basename(f) == "05_unknown_appointments.sql" &&
          "is_active" %in% DBI::dbListFields(con, "people") &&
          all(vapply(c("tenure_status", "graduate_faculty_status", "center_affiliations"),
            function(table) all(c("is_current", "recorded_on") %in% DBI::dbListFields(con, table)),
            logical(1)))) {
        cat("Already applied:", basename(f), "\n")
        next
      }
      cat("Running:", basename(f), "\n")
      DBI::dbExecute(con, readr::read_file(f))
    }
  }),
  error = function(e) {
    DBI::dbDisconnect(con, shutdown = TRUE)
    stop(e)
  }
)

# Quick check -----------------------------------------------------------------
cat("\nTables now in database:\n")
print(dbGetQuery(con, "SHOW TABLES;"))

dbDisconnect(con, shutdown = TRUE)
cat("\nSchema created/updated in:", db_path, "\n")

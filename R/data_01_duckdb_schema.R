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
for (f in sql_files) {
  cat("Running:", basename(f), "\n")
  stmt <- readr::read_file(f)
  DBI::dbExecute(con, stmt)
}

# Quick check -----------------------------------------------------------------
cat("\nTables now in database:\n")
print(dbGetQuery(con, "SHOW TABLES;"))

dbDisconnect(con)
cat("\nSchema created/updated in:", db_path, "\n")
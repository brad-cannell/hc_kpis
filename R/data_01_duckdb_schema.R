# =============================================================================
# scripts/01_create_schema.R
# Creates/updates the faculty_research.duckdb schema
# for people and person_appointments based on the SQL files in /sql.
# =============================================================================

# Load libraries --------------------------------------------------------------
library(DBI)
library(duckdb)
library(readr)

# Paths -----------------------------------------------------------------------
db_dir  <- "db"
sql_dir <- "sql"

db_path <- file.path("db", "faculty.duckdb")

# Connect to DuckDB -----------------------------------------------------------
con <- dbConnect(duckdb::duckdb(dbdir = db_path))

# Find and sort SQL files (01_..., 02_...)
sql_files <- list.files(sql_dir, pattern = "\\.sql$", full.names = TRUE)
sql_files <- sort(sql_files)

if (length(sql_files) == 0) {
  stop("No .sql files found in 'sql/' – add 01_people.sql and 02_person_appointments.sql first.")
}

# Execute each SQL file in order ---------------------------------------
for (f in sql_files) {
  cat("Running:", basename(f), "\n")
  stmt <- readr::read_file(f)
  DBI::dbExecute(con, stmt)
}

# Quick check -----------------------------------------------------------
cat("\nTables now in database:\n")
print(dbGetQuery(con, "SHOW TABLES;"))

dbDisconnect(con)

cat("\nSchema created/updated in:", db_path, "\n")

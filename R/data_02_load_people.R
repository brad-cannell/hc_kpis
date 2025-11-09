# R/data_02_load_people.R
# Load/update the `people` table in db/faculty.duckdb
# from data/faculty_people.csv

library(DBI)
library(duckdb)
library(readr)
library(dplyr)
library(uuid)

# --------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------
db_path   <- file.path("db", "faculty.duckdb")
data_path <- file.path("data", "faculty_people.csv")

if (!file.exists(db_path)) {
  stop("Database not found at ", db_path,
       ". Did you run R/data_01_duckdb_schema.R first?")
}

if (!file.exists(data_path)) {
  stop("Input CSV not found at ", data_path,
       ". Please create data/faculty_people.csv before running this script.")
}

# --------------------------------------------------------------------
# Connect to DuckDB
# --------------------------------------------------------------------
con <- dbConnect(duckdb::duckdb(dbdir = db_path))

# --------------------------------------------------------------------
# Read and clean CSV
# --------------------------------------------------------------------
raw_people <- readr::read_csv(data_path, show_col_types = FALSE)

# Make sure expected columns exist
expected_cols <- c("person_id", "first_name", "last_name", "email", "orcid")
missing_cols <- setdiff(expected_cols, names(raw_people))
if (length(missing_cols) > 0) {
  stop("Missing expected column(s) in faculty_people.csv: ",
       paste(missing_cols, collapse = ", "))
}

people_clean <- raw_people %>%
  mutate(
    # Trim whitespace
    first_name = trimws(first_name),
    last_name  = trimws(last_name),
    email      = trimws(email),
    orcid      = gsub("\\s", "", orcid),
    
    # Generate UUIDs where person_id is missing
    person_id  = ifelse(
      is.na(person_id) | person_id == "",
      UUIDgenerate(n = n()),
      person_id
    )
  )

# Basic validation: no missing names
if (any(is.na(people_clean$first_name) | people_clean$first_name == "")) {
  stop("Some rows have missing first_name. Please fix faculty_people.csv.")
}
if (any(is.na(people_clean$last_name) | people_clean$last_name == "")) {
  stop("Some rows have missing last_name. Please fix faculty_people.csv.")
}

# --------------------------------------------------------------------
# Upsert into `people`
# 
# Strategy:
#   - Create a temp staging table
#   - Delete any existing rows with the same person_id
#   - Insert cleaned rows
# This makes the script idempotent for the same CSV.
# --------------------------------------------------------------------

# Create empty staging table with same structure as people
dbExecute(con, "DROP TABLE IF EXISTS stg_people;")
dbExecute(con, "
  CREATE TEMP TABLE stg_people AS
  SELECT * FROM people WHERE 1=0;
")

# Append cleaned data into staging
dbWriteTable(con, "stg_people", people_clean, append = TRUE)

# Delete matches, then insert
dbExecute(con, "
  DELETE FROM people
  WHERE person_id IN (SELECT person_id FROM stg_people);
")

dbExecute(con, "
  INSERT INTO people
  SELECT * FROM stg_people;
")

# --------------------------------------------------------------------
# Sanity checks / preview
# --------------------------------------------------------------------
n_people <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM people")$n

preview <- dbGetQuery(con, "
  SELECT person_id, first_name, last_name, email, orcid
  FROM people
  ORDER BY last_name, first_name
  LIMIT 10;
")

dbDisconnect(con)

cat("Successfully loaded/updated people.\n")
cat("Total rows in people table:", n_people, "\n\n")
print(preview)

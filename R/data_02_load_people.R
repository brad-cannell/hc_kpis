# =============================================================================
# R/data_02_load_people.R
# Loads the `people` table from:
#   HC_KPIS/data/raw/faculty_roster_clean.csv
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

# Read & clean ----------------------------------------------------------------
raw <- readr::read_csv(data_path, show_col_types = FALSE)

# Expecting: given_name, family_name (plus other cols we ignore here)
people_clean <- raw |>
  select(given_name, family_name) |>
  distinct() |>
  rename(first_name = given_name, last_name = family_name) |>
  mutate(
    first_name = trimws(first_name),
    last_name  = trimws(last_name),
    person_id  = UUIDgenerate(n = n())
  ) |>
  select(person_id, first_name, last_name)

# Validate --------------------------------------------------------------------
if (any(is.na(people_clean$first_name) | people_clean$first_name == "")) {
  dbDisconnect(con); stop("Some rows have missing first_name.")
}
if (any(is.na(people_clean$last_name) | people_clean$last_name == "")) {
  dbDisconnect(con); stop("Some rows have missing last_name.")
}

# Upsert ----------------------------------------------------------------------
dbExecute(con, "DROP TABLE IF EXISTS stg_people;")
dbExecute(con, "CREATE TEMP TABLE stg_people AS SELECT * FROM people WHERE 1=0;")
dbWriteTable(con, "stg_people", people_clean, append = TRUE)
dbExecute(con, "DELETE FROM people WHERE person_id IN (SELECT person_id FROM stg_people);")
dbExecute(con, "INSERT INTO people SELECT * FROM stg_people;")

# Check -----------------------------------------------------------------------
n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM people")$n
cat("Rows in people:", n, "\n")
print(dbGetQuery(con, "SELECT * FROM people ORDER BY last_name, first_name LIMIT 10;"))

dbDisconnect(con)
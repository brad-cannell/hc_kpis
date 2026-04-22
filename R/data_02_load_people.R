# =============================================================================
# R/data_02_load_people.R
# Loads the `people` table from:
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

# Read & clean ----------------------------------------------------------------
raw <- readr::read_csv(data_path, show_col_types = FALSE)

# Expecting: given_name, family_name (plus other cols we ignore here)
people_clean <- raw |>
  select(given_name, family_name) |>
  distinct() |>
  rename(first_name = given_name, last_name = family_name) |>
  mutate(
    first_name = trimws(first_name),
    last_name  = trimws(last_name)
  ) |>
  filter(first_name != "", last_name != "") |>
  distinct(first_name, last_name) |>
  mutate(
    first_name_norm = tolower(first_name),
    last_name_norm  = tolower(last_name)
  )

# Validate --------------------------------------------------------------------
if (any(is.na(people_clean$first_name) | people_clean$first_name == "")) {
  dbDisconnect(con); stop("Some rows have missing first_name.")
}
if (any(is.na(people_clean$last_name) | people_clean$last_name == "")) {
  dbDisconnect(con); stop("Some rows have missing last_name.")
}

# Guardrail: fail fast if DB already has duplicate normalized names ------------
db_dupes <- dbGetQuery(con, "
  SELECT lower(trim(first_name)) AS first_name_norm,
         lower(trim(last_name))  AS last_name_norm,
         COUNT(*) AS n
  FROM people
  GROUP BY 1, 2
  HAVING COUNT(*) > 1;
")
if (nrow(db_dupes) > 0) {
  dbDisconnect(con)
  stop(
    "Existing duplicate people detected in database. Resolve duplicates before reloading.\n",
    paste0(
      head(paste0(db_dupes$first_name_norm, ' ', db_dupes$last_name_norm, ' (n=', db_dupes$n, ')'), 10),
      collapse = "\n"
    )
  )
}

# Upsert (idempotent) ---------------------------------------------------------
dbExecute(con, "DROP TABLE IF EXISTS stg_people;")
dbExecute(con, "
  CREATE TEMP TABLE stg_people (
    first_name      TEXT NOT NULL,
    last_name       TEXT NOT NULL,
    first_name_norm TEXT NOT NULL,
    last_name_norm  TEXT NOT NULL
  );
")
dbWriteTable(con, "stg_people", people_clean, append = TRUE)

# Update existing rows only if canonical values changed (e.g., spacing/case)
n_updated <- dbExecute(con, "
  UPDATE people AS p
  SET first_name = s.first_name,
      last_name  = s.last_name
  FROM stg_people AS s
  WHERE lower(trim(p.first_name)) = s.first_name_norm
    AND lower(trim(p.last_name))  = s.last_name_norm
    AND (p.first_name <> s.first_name OR p.last_name <> s.last_name);
")

# Insert only truly new people
to_insert <- dbGetQuery(con, "
  SELECT s.first_name, s.last_name
  FROM stg_people AS s
  LEFT JOIN people AS p
    ON lower(trim(p.first_name)) = s.first_name_norm
   AND lower(trim(p.last_name))  = s.last_name_norm
  WHERE p.person_id IS NULL;
")

n_inserted <- nrow(to_insert)
if (n_inserted > 0) {
  to_insert <- to_insert |>
    mutate(person_id = UUIDgenerate(n = n_inserted)) |>
    select(person_id, first_name, last_name)

  dbWriteTable(con, "stg_new_people", to_insert, temporary = TRUE, overwrite = TRUE)
  dbExecute(con, "INSERT INTO people SELECT person_id, first_name, last_name FROM stg_new_people;")
}

n_unchanged <- nrow(people_clean) - n_inserted - n_updated

# Check -----------------------------------------------------------------------
n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM people")$n
cat("Rows in people:", n, "\n")
cat("Inserted:", n_inserted, "| Updated:", n_updated, "| Unchanged:", n_unchanged, "\n")
print(dbGetQuery(con, "SELECT * FROM people ORDER BY last_name, first_name LIMIT 10;"))

dbDisconnect(con)

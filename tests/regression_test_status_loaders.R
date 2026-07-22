# =============================================================================
# tests/regression_test_status_loaders.R
# Verifies that a changed roster status produces exactly one current status row
# and that a later unchanged reload does not add history. The test runs in a
# temporary project copy so it never modifies production data or the database.
# =============================================================================

required_packages <- c("DBI", "duckdb", "readr", "dplyr", "uuid")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]

if (length(missing_packages) > 0) {
  stop("Install the required packages before running this test: ", paste(missing_packages, collapse = ", "))
}

# Locate the project from the test file rather than relying on the caller's
# working directory. This makes the script safe to run from an interactive R
# session, Rscript, or a project test command.
file_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
test_file <- if (length(file_argument) == 1L) {
  sub("^--file=", "", file_argument)
} else {
  file.path(getwd(), "tests", "regression_test_status_loaders.R")
}
test_file <- normalizePath(test_file, mustWork = TRUE)
project_dir <- normalizePath(file.path(dirname(test_file), ".."), mustWork = TRUE)
source_data <- file.path(project_dir, "data")

if (!file.exists(file.path(source_data, "raw", "faculty_roster_clean.csv"))) {
  stop("Source roster not found at ", file.path(source_data, "raw", "faculty_roster_clean.csv"))
}

test_dir <- tempfile("hc-kpis-status-loader-")
dir.create(test_dir)
on.exit(unlink(test_dir, recursive = TRUE, force = TRUE), add = TRUE)

# Copy only the components needed to build a fresh database. The real data
# folder may be a symlink to Dropbox, so copying it keeps the test independent
# of the production files while preserving the same input structure.
file.copy(file.path(project_dir, "R"), test_dir, recursive = TRUE)
file.copy(file.path(project_dir, "sql"), test_dir, recursive = TRUE)
dir.create(file.path(test_dir, "data", "raw"), recursive = TRUE)
file.copy(
  file.path(source_data, "raw", "faculty_roster_clean.csv"),
  file.path(test_dir, "data", "raw", "faculty_roster_clean.csv")
)
dir.create(file.path(test_dir, "db"))

# Work in the disposable project and create the initial current-status rows.
setwd(test_dir)
source("R/data_01_duckdb_schema.R")
source("R/data_02_load_people.R")
source("R/data_03_load_tenure_status.R")
source("R/data_04_load_grad_faculty_status.R")

# Make the first load look like yesterday's snapshot. This lets the test verify
# that a changed status is closed and replaced, rather than only testing the
# easier same-day-correction path.
con <- DBI::dbConnect(duckdb::duckdb("db/faculty.duckdb"))
initial_tenure_rows <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM tenure_status")$n[[1]]
initial_grad_rows <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM graduate_faculty_status")$n[[1]]
DBI::dbExecute(con, "UPDATE tenure_status SET valid_from = CURRENT_DATE - INTERVAL 1 DAY")
DBI::dbExecute(con, "UPDATE graduate_faculty_status SET valid_from = CURRENT_DATE - INTERVAL 1 DAY")
DBI::dbDisconnect(con)

# Change one complete roster row in each status dimension and rerun the
# loaders. The new status should replace, rather than duplicate, the old one.
roster <- readr::read_csv("data/raw/faculty_roster_clean.csv", show_col_types = FALSE)
changed_row <- 1L
changed_first_name <- roster$given_name[changed_row]
changed_last_name <- roster$family_name[changed_row]
changed_unit_code <- roster$unit_code[changed_row]
roster$track[changed_row] <- if (roster$track[changed_row] == "Tenured") "Tenure-Track" else "Tenured"
roster$is_graduate_faculty[changed_row] <- !roster$is_graduate_faculty[changed_row]
readr::write_csv(roster, "data/raw/faculty_roster_clean.csv")
source("R/data_03_load_tenure_status.R")
source("R/data_04_load_grad_faculty_status.R")

# Make the new current rows look like yesterday's snapshot, then reload the
# unchanged roster. If the loaders are idempotent across days, they leave the
# current rows untouched and do not add another history row.
con <- DBI::dbConnect(duckdb::duckdb("db/faculty.duckdb"))
DBI::dbExecute(con, "UPDATE tenure_status SET valid_from = CURRENT_DATE - INTERVAL 1 DAY WHERE valid_to IS NULL")
DBI::dbExecute(con, "UPDATE graduate_faculty_status SET valid_from = CURRENT_DATE - INTERVAL 1 DAY WHERE valid_to IS NULL")
DBI::dbDisconnect(con)
source("R/data_03_load_tenure_status.R")
source("R/data_04_load_grad_faculty_status.R")

con <- DBI::dbConnect(duckdb::duckdb("db/faculty.duckdb", read_only = TRUE))
on.exit(DBI::dbDisconnect(con), add = TRUE)

person_id <- DBI::dbGetQuery(
  con,
  "SELECT person_id FROM people WHERE first_name = ? AND last_name = ?",
  params = list(changed_first_name, changed_last_name)
)$person_id[[1]]

current_tenure <- DBI::dbGetQuery(
  con,
  "SELECT track FROM v_current_tenure WHERE person_id = ? AND unit_code = ?",
  params = list(person_id, changed_unit_code)
)
current_grad <- DBI::dbGetQuery(
  con,
  "SELECT is_graduate_faculty FROM v_current_grad_faculty WHERE person_id = ?",
  params = list(person_id)
)

stopifnot(nrow(current_tenure) == 1L)
stopifnot(current_tenure$track[[1]] == roster$track[changed_row])
stopifnot(nrow(current_grad) == 1L)
stopifnot(current_grad$is_graduate_faculty[[1]] == roster$is_graduate_faculty[changed_row])
stopifnot(DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM tenure_status")$n[[1]] == initial_tenure_rows + 1L)
stopifnot(DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM graduate_faculty_status")$n[[1]] == initial_grad_rows + 1L)

message("PASS: changed statuses have one current row and unchanged later reloads add no history.")

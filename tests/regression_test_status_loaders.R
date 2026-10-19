# Regression tests for unknown appointment fields, explicit activity, and history.
# Every write is confined to a disposable project; no production DB is opened.
library(DBI)
library(duckdb)
library(readr)

file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
test_file <- if (length(file_arg)) sub("^--file=", "", file_arg) else "tests/regression_test_status_loaders.R"
project_dir <- normalizePath(file.path(dirname(test_file), ".."))

#' Exercise legacy migration and roster loading in a disposable project
#' @param project_dir Repository containing the loaders and SQL.
#' @return Invisibly TRUE after all assertions pass.
run_regression <- function(project_dir) {
  scratch <- tempfile("hc-roster-regression-")
  dir.create(scratch)
  previous_wd <- getwd()
  on.exit({setwd(previous_wd); unlink(scratch, recursive = TRUE)}, add = TRUE)
  file.copy(file.path(project_dir, "R"), scratch, recursive = TRUE)
  file.copy(file.path(project_dir, "sql"), scratch, recursive = TRUE)
  dir.create(file.path(scratch, "db"))
  dir.create(file.path(scratch, "data", "raw"), recursive = TRUE)
  setwd(scratch)

  # Seed the fixed pre-migration schema with historical and current rows. Names
  # exercise approved identity/departure decisions, not fuzzy matching guesses.
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  dbExecute(con, read_file(file.path(project_dir, "tests", "fixtures", "legacy_schema.sql")))
  dbExecute(con, "INSERT INTO people VALUES
    ('alison', 'Alison', 'Prahl'), ('dennis', 'Dennis', 'Cheek'),
    ('mary', 'Mary', 'Twis'), ('ashley', 'Ashley', 'Franklin'),
    ('unreviewed', 'Ashlie', 'Seale'), ('known', 'Known', 'Person'),
    ('chris', 'Chris', 'Watts'), ('nada', 'Nada', 'Elias-Lambert')")
  dbExecute(con, "INSERT INTO tenure_status
    SELECT person_id || '-t', person_id, 'NURS', 'Nursing', 'Tenured',
           DATE '2020-01-01', NULL, 'faculty_roster_clean.csv', 'legacy'
    FROM people")
  dbExecute(con, "INSERT INTO graduate_faculty_status
    SELECT person_id || '-g', person_id, TRUE, DATE '2020-01-01', NULL,
           'faculty_roster_clean.csv', 'legacy' FROM people")
  dbExecute(con, "INSERT INTO tenure_status VALUES
    ('old-t', 'alison', 'COSD', 'COSD', 'Tenure-Track', DATE '2015-01-01',
     DATE '2019-12-31', 'faculty_roster_clean.csv', 'closed history')")
  dbExecute(con, "INSERT INTO center_affiliations VALUES
    ('known-c', 'known', 'CND', 'Center for Neurodegenerative Disease', TRUE,
     DATE '2020-01-01', NULL, 'faculty_roster_clean.csv', 'legacy')")
  before <- lapply(c("people", "tenure_status", "graduate_faculty_status", "center_affiliations"),
                   function(table) dbReadTable(con, table))
  names(before) <- c("people", "tenure_status", "graduate_faculty_status", "center_affiliations")
  dbDisconnect(con, shutdown = TRUE)

  source("R/data_01_duckdb_schema.R")
  source("R/data_01_duckdb_schema.R")
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  for (table in names(before)) {
    stopifnot(identical(dbReadTable(con, table)[names(before[[table]])], before[[table]]))
  }
  stopifnot(!dbGetQuery(con, "SELECT is_current FROM tenure_status WHERE tenure_id = 'old-t'")$is_current)
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: migration is repeatable and preserves every legacy field and row.")

  # Blank fields are intentionally retained for a new person. Existing people
  # receive sparse input to verify that unknown values cannot erase known facts.
  roster <- data.frame(
    given_name = c("Alison", "Known", "New", "Negative"),
    family_name = c("Hoyer", "Person", "Unknown", "Person"),
    unit_code = c("NURS", NA, NA, "COSD"),
    unit_name = c("Nursing", NA, NA, "COSD"),
    track = c("Tenured", NA, NA, "Professional Practice"),
    is_graduate_faculty = c(TRUE, NA, NA, FALSE),
    center_code = c(NA, "CND", NA, NA),
    center_name = c(NA, NA, NA, NA),
    is_primary = c(FALSE, TRUE, FALSE, FALSE)
  )
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  for (script in c("02_load_people", "03_load_tenure_status", "04_load_grad_faculty_status", "05_load_center_affiliations")) {
    source(paste0("R/data_", script, ".R"))
  }
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(dbGetQuery(con, "SELECT person_id FROM people WHERE last_name = 'Hoyer'")$person_id == "alison")
  stopifnot(identical(dbGetQuery(con, "SELECT is_active FROM people WHERE person_id IN ('dennis','mary','ashley','chris','nada')")$is_active, rep(FALSE, 5)))
  stopifnot(is.na(dbGetQuery(con, "SELECT is_active FROM people WHERE person_id = 'unreviewed'")$is_active))
  current <- dbGetQuery(con, "SELECT * FROM v_current_faculty")
  stopifnot(nrow(current) == 4L, !any(current$person_id %in% c("dennis", "mary", "ashley", "chris", "nada")))
  unknown <- current[current$first_name == "New", ]
  stopifnot(is.na(unknown$track), is.na(unknown$unit_code), is.na(unknown$is_graduate_faculty))
  stopifnot(identical(current$is_graduate_faculty[current$first_name == "Negative"], FALSE))
  known <- current[current$person_id == "known", ]
  stopifnot(known$track == "Tenured", known$unit_code == "NURS", known$is_graduate_faculty,
            known$center_name == "Center for Neurodegenerative Disease")
  # All legacy appointment fields, including departure-related rows and dates,
  # remain exactly as they were. Only newly added metadata may differ.
  for (table in names(before)[-1]) {
    now <- dbReadTable(con, table)
    key <- names(before[[table]])[1]
    legacy <- now[match(before[[table]][[key]], now[[key]]), names(before[[table]])]
    rownames(legacy) <- NULL
    stopifnot(identical(legacy, before[[table]]))
  }
  stopifnot(dbGetQuery(con, "SELECT count(*) n FROM tenure_status WHERE recorded_on IS NOT NULL AND valid_from IS NOT NULL")$n == 0)
  stopifnot(dbGetQuery(con, "SELECT count(*) n FROM graduate_faculty_status WHERE recorded_on IS NOT NULL AND valid_from IS NOT NULL")$n == 0)
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: rename keeps ID, departures stay historical, unknowns differ from FALSE, sparse inputs preserve facts.")

  # A genuine change creates a new assertion, even on the same day, without
  # inventing an end date for the prior fact or losing the previous row.
  roster$track[1] <- "Professional Practice"
  roster$is_graduate_faculty[1] <- FALSE
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  source("R/data_03_load_tenure_status.R")
  source("R/data_04_load_grad_faculty_status.R")
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(dbGetQuery(con, "SELECT track FROM v_current_tenure WHERE person_id='alison'")$track == "Professional Practice")
  old <- dbGetQuery(con, "SELECT * FROM tenure_status WHERE tenure_id='alison-t'")
  stopifnot(!old$is_current, is.na(old$valid_to), old$valid_from == as.Date("2020-01-01"))
  # Simulate an observation recorded yesterday, not a fake appointment start.
  for (table in names(before)[-1]) dbExecute(con, paste0("UPDATE ", table,
    " SET recorded_on = CURRENT_DATE - INTERVAL 1 DAY WHERE recorded_on IS NOT NULL"))
  snapshots <- lapply(names(before), function(table) dbReadTable(con, table))
  names(snapshots) <- names(before)
  dbDisconnect(con, shutdown = TRUE)
  for (script in c("01_duckdb_schema", "02_load_people", "03_load_tenure_status", "04_load_grad_faculty_status", "05_load_center_affiliations")) {
    source(paste0("R/data_", script, ".R"))
  }
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  for (table in names(snapshots)) stopifnot(identical(dbReadTable(con, table), snapshots[[table]]))
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: changed values preserve history; later unchanged reloads change no rows or dates.")

  # Removing a row cannot infer a departure, and a bad status must roll back
  # its entire loader. Checking data after the error catches partial updates.
  roster <- roster[-1, ]
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  source("R/data_02_load_people.R")
  source("R/data_03_load_tenure_status.R")
  source("R/data_04_load_grad_faculty_status.R")
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  for (table in names(snapshots)) stopifnot(identical(dbReadTable(con, table), snapshots[[table]]))
  dbDisconnect(con, shutdown = TRUE)
  roster$is_graduate_faculty <- as.character(roster$is_graduate_faculty)
  roster$is_graduate_faculty[3] <- "maybe"
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  stopifnot(inherits(try(source("R/data_04_load_grad_faculty_status.R"), silent = TRUE), "try-error"))
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(identical(dbReadTable(con, "graduate_faculty_status"), snapshots$graduate_faculty_status))
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: CSV absence preserves records; invalid input is rejected without mutation.")

  # Resolve an unknown appointment later, then prove a conflicting duplicate
  # aborts an otherwise-valid earlier change in the same loader transaction.
  roster$is_graduate_faculty[3] <- "FALSE"
  roster$unit_code[2] <- "COSD"
  roster$unit_name[2] <- "COSD"
  roster$track[2] <- "Tenure-Track"
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  source("R/data_03_load_tenure_status.R")
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  rows <- dbGetQuery(con, "SELECT * FROM v_current_tenure WHERE person_id = ?", params = list(unknown$person_id))
  stopifnot(nrow(rows) == 1L, rows$unit_code == "COSD", rows$track == "Tenure-Track")
  saved <- dbReadTable(con, "tenure_status")
  dbDisconnect(con, shutdown = TRUE)
  roster$track[1] <- "Professional Practice"
  conflicting <- roster[3, ]; conflicting$track <- "Tenured"
  write_csv(rbind(roster, conflicting), "data/raw/faculty_roster_clean.csv", na = "")
  stopifnot(inherits(try(source("R/data_03_load_tenure_status.R"), silent = TRUE), "try-error"))
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(identical(dbReadTable(con, "tenure_status"), saved))
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: unknown unit can be resolved without duplicate current rows; conflicting input rolls back.")

  # Force a failure after the first row has actually been changed. This tests
  # rollback of database mutations, not just rejection during input validation.
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  duplicate <- dbGetQuery(con, "SELECT * FROM tenure_status WHERE person_id = ? AND is_current IS TRUE",
                          params = list(unknown$person_id))
  duplicate$tenure_id <- "deliberate-duplicate"
  dbAppendTable(con, "tenure_status", duplicate)
  saved <- dbReadTable(con, "tenure_status")
  dbDisconnect(con, shutdown = TRUE)
  write_csv(roster, "data/raw/faculty_roster_clean.csv", na = "")
  stopifnot(inherits(try(source("R/data_03_load_tenure_status.R"), silent = TRUE), "try-error"))
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(identical(dbReadTable(con, "tenure_status"), saved))
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: an error after an earlier mutation rolls back the whole loader.")

  # Also exercise a brand-new database, whose CREATE statements already have
  # the new columns and therefore must not require the legacy migration.
  dir.create("fresh")
  file.copy("R", "fresh", recursive = TRUE)
  file.copy("sql", "fresh", recursive = TRUE)
  dir.create("fresh/db")
  dir.create("fresh/data/raw", recursive = TRUE)
  write_csv(roster, "fresh/data/raw/faculty_roster_clean.csv", na = "")
  setwd(file.path(scratch, "fresh"))
  for (script in c("01_duckdb_schema", "02_load_people", "03_load_tenure_status", "04_load_grad_faculty_status", "05_load_center_affiliations")) {
    source(paste0("R/data_", script, ".R"))
  }
  con <- dbConnect(duckdb("db/faculty.duckdb"))
  stopifnot(dbGetQuery(con, "SELECT count(*) n FROM v_current_faculty")$n == nrow(roster))
  dbDisconnect(con, shutdown = TRUE)
  message("PASS: a new database supports the same nullable fields and loaders.")
  invisible(TRUE)
}
run_regression(project_dir)
message("ALL ROSTER REGRESSION CHECKS PASSED")

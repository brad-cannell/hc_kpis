# Rehearse the complete refresh against the actual roster and a disposable copy
# of database rows/schema. The working database is opened read-only throughout.
library(DBI)
library(duckdb)
library(readr)

file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
test_file <- if (length(file_arg)) sub("^--file=", "", file_arg) else "tests/rehearse_roster_refresh.R"
project_dir <- normalizePath(file.path(dirname(test_file), ".."))

#' Rehearse migration/loading and UI checks without modifying working data
#' @param project_dir Repository with the working database and CSV links.
#' @return Invisibly TRUE after preservation and repeatability checks pass.
rehearse_refresh <- function(project_dir) {
  scratch <- tempfile("hc-roster-rehearsal-")
  dir.create(scratch)
  old_wd <- getwd()
  on.exit({setwd(old_wd); unlink(scratch, recursive = TRUE)}, add = TRUE)
  working <- dbConnect(duckdb(file.path(project_dir, "db", "faculty.duckdb"), read_only = TRUE))
  on.exit(dbDisconnect(working, shutdown = TRUE), add = TRUE)
  tables <- c("people", "tenure_status", "graduate_faculty_status", "center_affiliations")
  baseline <- setNames(lapply(tables, function(table) dbReadTable(working, table)), tables)
  csv_path <- file.path(project_dir, "data", "raw", "faculty_roster_clean.csv")
  csv_before <- read_file(csv_path)

  # Copy rows through read-only queries rather than copying a potentially live
  # database file. Keep IDs, constraints, indexes, and legacy views unchanged.
  file.copy(file.path(project_dir, "R"), scratch, recursive = TRUE)
  file.copy(file.path(project_dir, "sql"), scratch, recursive = TRUE)
  dir.create(file.path(scratch, "db"))
  dir.create(file.path(scratch, "data", "raw"), recursive = TRUE)
  write_file(csv_before, file.path(scratch, "data", "raw", "faculty_roster_clean.csv"))
  copied_db <- file.path(scratch, "db", "faculty.duckdb")
  copy <- dbConnect(duckdb(copied_db))
  for (table in tables) {
    ddl <- dbGetQuery(working, "SELECT sql FROM duckdb_tables() WHERE schema_name='main' AND table_name=?",
                      params = list(table))$sql
    dbExecute(copy, ddl)
    dbAppendTable(copy, table, baseline[[table]])
  }
  for (ddl in dbGetQuery(working, "SELECT sql FROM duckdb_indexes() WHERE schema_name='main'")$sql) dbExecute(copy, ddl)
  for (view in c("v_current_tenure", "v_current_grad_faculty", "v_current_center_affiliations", "v_current_faculty")) {
    ddl <- dbGetQuery(working, "SELECT sql FROM duckdb_views() WHERE schema_name='main' AND view_name=?",
                      params = list(view))$sql
    if (length(ddl)) dbExecute(copy, ddl)
  }
  dbDisconnect(copy, shutdown = TRUE)
  setwd(scratch)
  for (script in c("01_duckdb_schema", "02_load_people", "03_load_tenure_status", "04_load_grad_faculty_status", "05_load_center_affiliations")) {
    source(paste0("R/data_", script, ".R"))
  }

  copy <- dbConnect(duckdb(copied_db, read_only = TRUE))
  after <- setNames(lapply(tables, function(table) dbReadTable(copy, table)), tables)
  stopifnot(all(baseline$people$person_id %in% after$people$person_id))
  for (table in tables[-1]) {
    # Appointment assertions may be superseded, but every old fact/date/ID must
    # still be present. Only the new is_current flag may change after migration.
    fields <- setdiff(names(baseline[[table]]), "is_current")
    key <- fields[1]
    preserved <- after[[table]][match(baseline[[table]][[key]], after[[table]][[key]]), fields]
    rownames(preserved) <- NULL
    stopifnot(identical(preserved, baseline[[table]][fields]))
  }
  current <- dbGetQuery(copy, "SELECT * FROM v_current_faculty")
  stopifnot(length(unique(current$person_id)) == 124L)
  stopifnot(sum(after$people$is_active %in% FALSE) == 5L)
  # Brad resolved Chris and Nada as inactive; Ashlie still needs confirmation.
  stopifnot(identical(paste(after$people$first_name[is.na(after$people$is_active)],
                           after$people$last_name[is.na(after$people$is_active)]), "Ashlie Seale"))
  stopifnot(nrow(after$center_affiliations) == nrow(baseline$center_affiliations))
  alison_before <- baseline$people$person_id[baseline$people$first_name == "Alison" & baseline$people$last_name %in% c("Prahl", "Hoyer")]
  stopifnot(identical(after$people$person_id[after$people$first_name == "Alison" & after$people$last_name == "Hoyer"], alison_before))
  cat("REHEARSAL: people=", nrow(after$people), "; current faculty=", length(unique(current$person_id)),
      "; inactive=", sum(after$people$is_active %in% FALSE), "; activity unreviewed=", sum(is.na(after$people$is_active)),
      "; missing tracks=", sum(is.na(current$track)), "; missing grad status=", sum(is.na(current$is_graduate_faculty)),
      "; missing units=", sum(is.na(current$unit_code)), "; centers=", nrow(after$center_affiliations), "\n", sep = "")
  dbDisconnect(copy, shutdown = TRUE)

  # Repeating the full sequence must be a no-op, including the identity rename,
  # new nullable statuses, and all five existing CND affiliations.
  for (script in c("01_duckdb_schema", "02_load_people", "03_load_tenure_status", "04_load_grad_faculty_status", "05_load_center_affiliations")) {
    source(paste0("R/data_", script, ".R"))
  }
  copy <- dbConnect(duckdb(copied_db, read_only = TRUE))
  for (table in tables) stopifnot(identical(dbReadTable(copy, table), after[[table]]))
  dbDisconnect(copy, shutdown = TRUE)

  # Run the existing finder checks against the migrated disposable database,
  # including its unknown-value display and synthetic joint-appointment cases.
  setwd(project_dir)
  status <- system2(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(file.path(project_dir, "tests", "test_faculty_finder.R"))),
    env = paste0("HC_KPIS_TEST_DB=", shQuote(copied_db)))
  stopifnot(status == 0L)
  for (table in tables) stopifnot(identical(dbReadTable(working, table), baseline[[table]]))
  stopifnot(identical(read_file(csv_path), csv_before))
  message("PASS: all original IDs/history retained, full reload unchanged, finder checks passed; working data untouched.")
  invisible(TRUE)
}
rehearse_refresh(project_dir)

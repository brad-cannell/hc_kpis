# =============================================================================
# tests/test_faculty_finder.R
# Verifies the Faculty Finder's filter and display logic against UI_SPEC.md.
# The app's R functions are compared with independently written DuckDB SQL,
# first on the working database (opened read-only) and then on a disposable
# copy that adds synthetic people for cases the real roster does not contain:
# a joint appointment, extra centers (one without a name), and a person with no
# appointment, graduate-faculty, or center records. It also checks the app's
# missing-database, out-of-date-schema, and locked-database messages. The test
# never writes to the working database or the Dropbox roster.
# =============================================================================

required_packages <- c("DBI", "duckdb", "shiny")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]

if (length(missing_packages) > 0) {
  stop("Install the required packages before running this test: ", paste(missing_packages, collapse = ", "))
}

# Locate the project from the test file rather than relying on the caller's
# working directory, matching tests/regression_test_status_loaders.R.
file_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
test_file <- if (length(file_argument) == 1L) {
  sub("^--file=", "", file_argument)
} else {
  file.path(getwd(), "tests", "test_faculty_finder.R")
}
test_file <- normalizePath(test_file, mustWork = TRUE)
project_dir <- normalizePath(file.path(dirname(test_file), ".."), mustWork = TRUE)
setwd(project_dir)

if (!file.exists(file.path(project_dir, "db", "faculty.duckdb"))) {
  stop("Working database not found at db/faculty.duckdb. Run the five loader scripts first.")
}

# Load the app's function definitions without starting Shiny: evaluate every
# top-level expression in app/app.R except the final shinyApp() call. This also
# defines database_path, which points at the working database.
app_expressions <- parse("app/app.R")
for (expression in app_expressions[-length(app_expressions)]) eval(expression, globalenv())

# The synthetic database lives in R's session temporary folder, which R removes
# when the session ends.
scratch <- tempfile("hc-kpis-faculty-finder-")
dir.create(scratch)

failures <- character()
check <- function(ok, label) {
  if (!isTRUE(ok)) failures <<- c(failures, label)
  invisible(ok)
}

# SQL for the displayed unit label; mirrors the rule in UI_SPEC.md, written
# separately from display_unit().
unit_label_sql <- "CASE
  WHEN nullif(unit_name, '') IS NOT NULL AND nullif(unit_code, '') IS NOT NULL THEN unit_name || ' (' || unit_code || ')'
  WHEN nullif(unit_name, '') IS NOT NULL THEN unit_name
  WHEN nullif(unit_code, '') IS NOT NULL THEN unit_code
  ELSE 'Not recorded' END"

sql_quote <- function(x) paste0("'", gsub("'", "''", x), "'")
sql_in <- function(x) paste(sql_quote(x), collapse = ", ")

# Independent person-set query for one filter combination.
sql_people <- function(con, q, units, tracks, grad, center) {
  where <- "TRUE"
  q <- tolower(trimws(q))
  if (nzchar(q)) {
    where <- paste0(where, " AND strpos(lower(first_name || ' ' || last_name || ' ' || last_name || ', ' || first_name), ", sql_quote(q), ") > 0")
  }
  if (length(units)) where <- paste0(where, " AND (", unit_label_sql, ") IN (", sql_in(units), ")")
  if (length(tracks)) where <- paste0(where, " AND track IN (", sql_in(tracks), ")")

  grad_having <- switch(grad,
    "Yes" = "bool_or(is_graduate_faculty)",
    "No" = "count(is_graduate_faculty) > 0 AND NOT bool_or(is_graduate_faculty)",
    "Not recorded" = "count(is_graduate_faculty) = 0",
    NULL
  )
  if (!is.null(grad_having)) {
    where <- paste0(where, " AND person_id IN (SELECT person_id FROM v_current_faculty GROUP BY person_id HAVING ", grad_having, ")")
  }

  affiliated <- "SELECT person_id FROM v_current_faculty WHERE nullif(center_code, '') IS NOT NULL"
  if (identical(center, ".any")) where <- paste0(where, " AND person_id IN (", affiliated, ")")
  if (identical(center, ".none")) where <- paste0(where, " AND person_id NOT IN (", affiliated, ")")
  if (!center %in% c(".all", ".any", ".none")) {
    where <- paste0(where, " AND person_id IN (SELECT person_id FROM v_current_faculty WHERE center_code = ", sql_quote(center), ")")
  }

  sort(DBI::dbGetQuery(con, paste("SELECT DISTINCT person_id FROM v_current_faculty WHERE", where))$person_id)
}

app_people <- function(data, q, units, tracks, grad, center) {
  sort(filter_people(data, q, units, tracks, grad, center)$person_id)
}

# Run the full comparison suite against one database file.
verify_database <- function(db_file, label) {
  state <- read_current_faculty(db_file)
  check(identical(state$status, "ready"), paste(label, "loads"))
  data <- state$data
  con <- DBI::dbConnect(duckdb::duckdb(db_file), read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Filter choices built by the app versus SQL.
  sql_units <- sort(DBI::dbGetQuery(con, paste("SELECT DISTINCT", unit_label_sql, "AS u FROM v_current_faculty"))$u)
  app_units <- sort(unique(vapply(seq_len(nrow(data)), function(i) display_unit(data$unit_name[[i]], data$unit_code[[i]]), "")))
  check(identical(sql_units, app_units), paste(label, "unit choices"))
  tracks <- sort(DBI::dbGetQuery(con, "SELECT DISTINCT track FROM v_current_faculty WHERE track IS NOT NULL")$track)

  sql_centers <- DBI::dbGetQuery(con, "SELECT center_code, any_value(nullif(center_name, '')) AS center_name
    FROM v_current_faculty WHERE nullif(center_code, '') IS NOT NULL GROUP BY center_code
    ORDER BY center_code <> 'CND', center_code")
  expected_labels <- c("All", "Any center or institute", "No center or institute",
    ifelse(is.na(sql_centers$center_name), sql_centers$center_code, paste0(sql_centers$center_name, " (", sql_centers$center_code, ")")))
  choices <- center_choices(data)
  check(identical(unname(names(choices)), expected_labels), paste(label, "center choice labels and order"))
  check(identical(unname(choices), c(".all", ".any", ".none", sql_centers$center_code)), paste(label, "center choice values"))
  centers <- unname(choices)

  # Every single filter value, every unit x track pair, then random combinations.
  n <- 0
  compare <- function(q = "", u = character(), t = character(), g = "All", c = ".all") {
    n <<- n + 1
    ok <- identical(app_people(data, q, u, t, g, c), sql_people(con, q, u, t, g, c))
    check(ok, sprintf("%s filter q='%s' units=[%s] tracks=[%s] grad=%s center=%s", label, q, paste(u, collapse = "|"), paste(t, collapse = "|"), g, c))
  }
  compare()
  for (u in sql_units) compare(u = u)
  for (t in tracks) compare(t = t)
  for (u in sql_units) for (t in tracks) compare(u = u, t = t)
  for (g in c("Yes", "No", "Not recorded")) compare(g = g)
  for (c in centers) compare(c = c)
  names_all <- tolower(c(data$first_name, data$last_name))
  for (q in c("a", "RIV", "  ann ", "rivera, ", "zzzz", paste(data$first_name[1], data$last_name[1]))) compare(q = q)

  set.seed(20260925)
  for (i in 1:300) {
    name <- sample(names_all, 1)
    start <- sample(seq_len(max(1, nchar(name) - 2)), 1)
    q <- if (runif(1) < 0.5) "" else substr(name, start, start + 2)
    compare(
      q = q,
      u = sample(sql_units, sample(0:2, 1)),
      t = sample(tracks, sample(0:2, 1)),
      g = sample(c("All", "Yes", "No", "Not recorded"), 1),
      c = sample(centers, 1)
    )
  }

  # Displayed fields versus SQL, person by person.
  people <- filter_people(data, "", character(), character(), "All", ".all")
  sql_display <- DBI::dbGetQuery(con, paste0("
    WITH pairs AS (
      SELECT DISTINCT person_id, ", unit_label_sql, " AS unit, coalesce(nullif(track, ''), 'Not recorded') AS track
      FROM v_current_faculty),
    ctr AS (
      SELECT person_id, string_agg(DISTINCT center_code, '; ' ORDER BY center_code <> 'CND', center_code) AS centers
      FROM v_current_faculty WHERE nullif(center_code, '') IS NOT NULL GROUP BY person_id),
    grad AS (
      SELECT person_id, CASE WHEN count(is_graduate_faculty) = 0 THEN 'Not recorded'
        WHEN bool_or(is_graduate_faculty) THEN 'Yes' ELSE 'No' END AS graduate_status
      FROM v_current_faculty GROUP BY person_id)
    SELECT p.person_id, p.last_name, p.first_name,
      string_agg(pairs.unit, chr(10) ORDER BY pairs.unit, pairs.track) AS units,
      string_agg(pairs.track, chr(10) ORDER BY pairs.unit, pairs.track) AS tracks,
      any_value(grad.graduate_status) AS graduate_status,
      coalesce(any_value(ctr.centers), 'None') AS centers
    FROM people p JOIN pairs USING (person_id) JOIN grad USING (person_id) LEFT JOIN ctr USING (person_id)
    GROUP BY ALL"))
  cols <- c("person_id", "last_name", "first_name", "units", "tracks", "graduate_status", "centers")
  a <- people[order(people$person_id), cols]; rownames(a) <- NULL
  s <- sql_display[order(sql_display$person_id), cols]; rownames(s) <- NULL
  check(identical(nrow(a), nrow(s)), paste(label, "person count"))
  for (col in cols[-1]) check(identical(a[[col]], s[[col]]), paste(label, "display column", col))

  # Default order: last name, then first name.
  sql_order <- DBI::dbGetQuery(con, "SELECT DISTINCT person_id, lower(last_name) l, lower(first_name) f FROM v_current_faculty ORDER BY l, f")$person_id
  check(identical(people$person_id, sql_order), paste(label, "default sort order"))

  cat(sprintf("%s: %d people, %d filter comparisons\n", label, nrow(people), n))
  data
}

live_data <- verify_database(database_path, "live")

# Synthetic copy: never touches the working database. The joint appointment
# reuses the real NURS and SOWO unit names so its labels match the unit
# choices built from real data.
synthetic_db <- file.path(scratch, "db", "faculty.duckdb")
dir.create(dirname(synthetic_db), recursive = TRUE, showWarnings = FALSE)
invisible(file.copy(database_path, synthetic_db, overwrite = TRUE))
con <- DBI::dbConnect(duckdb::duckdb(synthetic_db))
units <- DBI::dbGetQuery(con, "SELECT unit_code, any_value(unit_name) unit_name FROM tenure_status WHERE unit_code IN ('NURS', 'SOWO') GROUP BY unit_code ORDER BY unit_code")
if (nrow(units) != 2L) {
  DBI::dbDisconnect(con, shutdown = TRUE)
  stop("The synthetic checks need NURS and SOWO rows in tenure_status.")
}
invisible(DBI::dbExecute(con, "INSERT INTO people VALUES ('syn-1', 'Zed', 'Aajoint'), ('syn-2', 'Amy', 'Aacenter'), ('syn-3', 'Nora', 'Aanorecords')"))
invisible(DBI::dbExecute(con, sprintf("INSERT INTO tenure_status (tenure_id, person_id, unit_code, unit_name, track, valid_from) VALUES
  ('syn-t1', 'syn-1', 'SOWO', %s, 'Professional Practice', DATE '2020-01-01'),
  ('syn-t2', 'syn-1', 'NURS', %s, 'Tenured', DATE '2020-01-01'),
  ('syn-t3', 'syn-2', 'NURS', %s, 'Tenure-Track', DATE '2020-01-01')",
  sql_quote(units$unit_name[units$unit_code == "SOWO"]), sql_quote(units$unit_name[units$unit_code == "NURS"]), sql_quote(units$unit_name[units$unit_code == "NURS"]))))
invisible(DBI::dbExecute(con, "INSERT INTO graduate_faculty_status (grad_id, person_id, is_graduate_faculty, valid_from) VALUES
  ('syn-g1', 'syn-1', TRUE, DATE '2020-01-01'), ('syn-g2', 'syn-2', FALSE, DATE '2020-01-01')"))
invisible(DBI::dbExecute(con, "INSERT INTO center_affiliations (affiliation_id, person_id, center_code, center_name, valid_from) VALUES
  ('syn-c1', 'syn-1', 'ZZI', 'Zeta Test Institute', DATE '2020-01-01'),
  ('syn-c2', 'syn-1', 'CND', 'Center for Neurodegenerative Disease', DATE '2020-01-01'),
  ('syn-c3', 'syn-2', 'ABC', NULL, DATE '2020-01-01')"))
DBI::dbDisconnect(con, shutdown = TRUE)

syn_data <- verify_database(synthetic_db, "synthetic")

# Specific expectations the generic comparison cannot express.
syn_people <- filter_people(syn_data, "", character(), character(), "All", ".all")
joint <- syn_people[syn_people$person_id == "syn-1", ]
check(nrow(joint) == 1, "joint appointment is one row")
check(identical(joint$units, paste(sprintf("%s (%s)", units$unit_name, units$unit_code), collapse = "\n")), "joint units: one line each, NURS first")
check(identical(joint$tracks, "Tenured\nProfessional Practice"), "joint tracks align with units")
check(identical(joint$centers, "CND; ZZI"), "joint person centers CND first")
check(identical(syn_people$centers[syn_people$person_id == "syn-2"], "ABC"), "unnamed center shown by code")
none_row <- syn_people[syn_people$person_id == "syn-3", ]
check(identical(c(none_row$units, none_row$tracks, none_row$graduate_status, none_row$centers), c("Not recorded", "Not recorded", "Not recorded", "None")), "person with no records")
nurs <- sprintf("%s (%s)", units$unit_name[units$unit_code == "NURS"], "NURS")
check(!"syn-1" %in% filter_people(syn_data, "", nurs, "Professional Practice", "All", ".all")$person_id, "same-appointment rule excludes NURS x Professional Practice")
check("syn-1" %in% filter_people(syn_data, "", nurs, "Tenured", "All", "ZZI")$person_id, "NURS x Tenured x ZZI finds joint person")
check(identical(unname(names(center_choices(syn_data)))[4:6], c("Center for Neurodegenerative Disease (CND)", "ABC", "Zeta Test Institute (ZZI)")), "synthetic dropdown order")

# Error states. The schema check drops center_name from the view, which the
# revised app needs for the Center or institute dropdown labels.
check(identical(read_current_faculty(file.path(scratch, "missing.duckdb"))$status, "database_error"), "missing database")
schema_db <- file.path(scratch, "schema.duckdb")
invisible(file.copy(synthetic_db, schema_db, overwrite = TRUE))
con <- DBI::dbConnect(duckdb::duckdb(schema_db))
invisible(DBI::dbExecute(con, "CREATE OR REPLACE VIEW v_current_faculty AS SELECT p.person_id, p.first_name, p.last_name, t.unit_code, t.unit_name, t.track, g.is_graduate_faculty, c.center_code
  FROM people p LEFT JOIN v_current_tenure t USING (person_id) LEFT JOIN v_current_grad_faculty g USING (person_id) LEFT JOIN v_current_center_affiliations c USING (person_id)"))
DBI::dbDisconnect(con, shutdown = TRUE)
check(identical(read_current_faculty(schema_db)$status, "schema_error"), "view without center_name is a schema error")

# Locked database: hold a writer in this process and read from a child
# process, because DuckDB allows only one process to hold the write lock.
con <- DBI::dbConnect(duckdb::duckdb(synthetic_db))
child <- system2(file.path(R.home("bin"), "Rscript"), c("-e", shQuote(sprintf(
  "e <- parse('app/app.R'); for (x in e[-length(e)]) eval(x); cat(read_current_faculty('%s')$status)", synthetic_db))),
  stdout = TRUE, stderr = FALSE, env = "RENV_CONFIG_AUTOLOADER_ENABLED=FALSE")
DBI::dbDisconnect(con, shutdown = TRUE)
check(identical(tail(child, 1), "database_error"), "locked database")

unlink(scratch, recursive = TRUE, force = TRUE)

# Exit non-zero on failure so the result is unambiguous from the shell.
if (length(failures)) {
  cat("FAILURES (", length(failures), "):\n", paste("-", head(failures, 40), collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
cat("ALL CHECKS PASSED\n")

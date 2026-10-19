# Shared validation and history rules for the three appointment loaders.
# Brad's October 2026 decisions: blanks are unknown, absence is not a departure,
# and the date we learn a fact must not become an invented appointment date.

#' Read roster text without silently converting invalid status values
#' @param path Path to the working CSV.
#' @return A tibble with trimmed text and empty cells represented by NA.
read_roster <- function(path) {
  raw <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                         na = c("", "NA"), show_col_types = FALSE)
  raw <- dplyr::mutate(raw, dplyr::across(dplyr::everything(), ~dplyr::na_if(trimws(.x), "")))
  if (!all(c("given_name", "family_name") %in% names(raw)) ||
      anyNA(raw$given_name) || anyNA(raw$family_name)) {
    stop("Every roster row must have a given_name and family_name.")
  }
  raw
}

#' Parse a three-state boolean without turning unknown into false
#' @param x Character values from a CSV boolean field.
#' @param field Field name for a validation error.
#' @return A logical vector, including NA for unknown values.
roster_boolean <- function(x, field) {
  x <- toupper(x)
  if (any(!is.na(x) & !x %in% c("TRUE", "FALSE"))) {
    stop("Invalid ", field, "; use TRUE, FALSE, or blank.")
  }
  as.logical(x)
}

#' Match roster names to existing people without creating identities
#' @param con An open DuckDB connection.
#' @param raw A roster read with read_roster().
#' @return The roster with person_id appended.
match_roster_people <- function(con, raw) {
  people <- DBI::dbGetQuery(con, "SELECT person_id, lower(trim(first_name)) AS first_key,
                                  lower(trim(last_name)) AS last_key FROM people")
  matched <- raw |>
    dplyr::mutate(first_key = tolower(given_name), last_key = tolower(family_name)) |>
    dplyr::left_join(people, by = c("first_key", "last_key"), relationship = "many-to-one")
  if (anyNA(matched$person_id)) stop("Unmatched people; run the people loader first.")
  matched
}

#' Run one loader atomically and always release its database connection
#' @param work Function accepting an open DuckDB connection.
#' @param db_path Existing database path; tests use a disposable project.
#' @return The result of work().
with_roster_db <- function(work, db_path = file.path("db", "faculty.duckdb")) {
  if (!file.exists(db_path)) stop("Database not found; run the schema script first.")
  con <- DBI::dbConnect(duckdb::duckdb(dbdir = db_path))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWithTransaction(con, work(con))
}

#' Record appointment assertions while retaining all previous rows
#' @param con An open DuckDB connection inside a transaction.
#' @param table Appointment table name, supplied by a loader.
#' @param id_column Primary-key column for the appointment table.
#' @param incoming Validated appointment data with person_id and source.
#' @param keys Columns identifying the appointment within a source.
#' @param values Appointment attributes whose changes create a new assertion.
#' @return Invisibly, the number of inserted observations.
record_roster_status <- function(con, table, id_column, incoming, keys, values) {
  # Reject conflicting source rows instead of allowing file order to choose a
  # status. Identical repeats (e.g., a joint appointee's graduate flag) collapse.
  incoming <- dplyr::distinct(incoming)
  if (anyDuplicated(incoming[c(keys, "source")])) {
    stop("Conflicting roster rows for ", table, ".")
  }
  inserted <- 0L
  for (i in seq_len(nrow(incoming))) {
    row <- incoming[i, , drop = FALSE]
    predicate <- paste(paste0(c(keys, "source"), " IS NOT DISTINCT FROM ?"), collapse = " AND ")
    previous <- DBI::dbGetQuery(con,
      paste0("SELECT * FROM ", table, " WHERE is_current IS TRUE AND ", predicate),
      params = unname(as.list(row[c(keys, "source")])))

    # When an unknown unit becomes known, replace only the lone unknown-unit
    # assertion. Multiple incoming units need an explicit appointment match.
    if (table == "tenure_status" && nrow(previous) == 0L && !is.na(row$unit_code)) {
      previous <- DBI::dbGetQuery(con,
        "SELECT * FROM tenure_status WHERE person_id = ? AND source = ?
         AND unit_code IS NULL AND is_current IS TRUE",
        params = list(row$person_id, row$source))
      if (nrow(previous) && sum(incoming$person_id == row$person_id) > 1L) {
        stop("Ambiguous unknown-unit appointment; review before loading.")
      }
    }
    if (nrow(previous) > 1L) stop("Multiple current assertions in ", table, "; review before loading.")

    if (nrow(previous) == 1L) {
      # An incomplete source must not overwrite a known attribute. This also
      # keeps an unchanged reload from manufacturing another history row.
      for (field in values) {
        if (is.na(row[[field]])) row[[field]] <- previous[[field]]
      }
      unchanged <- all(vapply(c(keys, values), function(field) {
        old <- previous[[field]]; new <- row[[field]]
        (is.na(old) && is.na(new)) || (!is.na(old) && !is.na(new) && old == new)
      }, logical(1)))
      if (unchanged) next
      DBI::dbExecute(con, paste0("UPDATE ", table, " SET is_current = FALSE WHERE ", id_column, " = ?"),
                     params = list(previous[[id_column]]))
    }

    # New observations have unknown effective dates. Old dates and old rows
    # are retained even for a same-day correction. recorded_on is not a hire,
    # promotion, departure, or graduate-appointment date.
    row[[id_column]] <- uuid::UUIDgenerate()
    row$valid_from <- as.Date(NA)
    row$valid_to <- as.Date(NA)
    row$is_current <- TRUE
    row$recorded_on <- Sys.Date()
    row$notes <- NA_character_
    DBI::dbAppendTable(con, table, row)
    inserted <- inserted + 1L
  }
  message(table, ": ", inserted, " new observations; no historical rows deleted.")
  invisible(inserted)
}

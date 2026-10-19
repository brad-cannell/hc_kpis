# Load known appointment attributes while accepting unknown unit/track/dates.
# Missing rows are not evidence that an appointment ended.
source("R/roster_helpers.R")

with_roster_db(function(con) {
  tenure <- match_roster_people(con, read_roster("data/raw/faculty_roster_clean.csv")) |>
    dplyr::select(person_id, unit_code, unit_name, track) |>
    dplyr::mutate(source = "faculty_roster_clean.csv") |>
    dplyr::distinct()
  allowed <- c("Tenured", "Tenure-Track", "Professional Practice")
  if (any(!is.na(tenure$track) & !tenure$track %in% allowed)) {
    stop("Invalid track; use Tenured, Tenure-Track, Professional Practice, or blank.")
  }

  # Preserve an existing unit when an incomplete row clearly describes one
  # appointment. Joint appointments need an explicit unit match, not a guess.
  for (i in which(is.na(tenure$unit_code))) {
    previous <- DBI::dbGetQuery(con, "SELECT unit_code FROM tenure_status
      WHERE person_id = ? AND source = 'faculty_roster_clean.csv' AND is_current IS TRUE",
      params = list(tenure$person_id[i]))
    if (nrow(previous) > 1L) stop("Missing unit for a person with multiple appointments; review before loading.")
    if (nrow(previous) == 1L) tenure$unit_code[i] <- previous$unit_code
  }
  record_roster_status(con, "tenure_status", "tenure_id", tenure,
                       c("person_id", "unit_code"), c("unit_name", "track"))
})

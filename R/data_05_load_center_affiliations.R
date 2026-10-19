# Preserve known affiliations and add only changed observations. A blank center
# does not end an affiliation, and a routine reload must not duplicate one.
source("R/roster_helpers.R")

with_roster_db(function(con) {
  raw <- read_roster("data/raw/faculty_roster_clean.csv")
  if (!"center_code" %in% names(raw)) {
    message("No center column; existing affiliations preserved.")
  } else {
    if (!"center_name" %in% names(raw)) raw$center_name <- NA_character_
    if (!"is_primary" %in% names(raw)) raw$is_primary <- NA_character_
    centers <- match_roster_people(con, raw) |>
      dplyr::filter(!is.na(center_code)) |>
      dplyr::transmute(person_id, center_code, center_name,
        is_primary = roster_boolean(is_primary, "is_primary"),
        source = "faculty_roster_clean.csv") |>
      dplyr::distinct()
    # Existing center records can supply a missing primary flag. For a new
    # affiliation, require an explicit value instead of inventing a primary role.
    for (i in which(is.na(centers$is_primary))) {
      previous <- DBI::dbGetQuery(con, "SELECT is_primary FROM center_affiliations
        WHERE person_id = ? AND center_code = ? AND source = 'faculty_roster_clean.csv'
          AND is_current IS TRUE", params = list(centers$person_id[i], centers$center_code[i]))
      if (nrow(previous) != 1L) stop("New/ambiguous center affiliation needs is_primary.")
      centers$is_primary[i] <- previous$is_primary
    }
    record_roster_status(con, "center_affiliations", "affiliation_id", centers,
                         c("person_id", "center_code"), c("center_name", "is_primary"))
  }
})

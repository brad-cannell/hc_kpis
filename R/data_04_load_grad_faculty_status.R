# TRUE, FALSE, and unknown graduate status are distinct. Eva's approved Fall
# 2026 corrections are in the working CSV; absence from her list is not FALSE.
source("R/roster_helpers.R")

with_roster_db(function(con) {
  grad <- match_roster_people(con, read_roster("data/raw/faculty_roster_clean.csv")) |>
    dplyr::transmute(person_id,
      is_graduate_faculty = roster_boolean(is_graduate_faculty, "is_graduate_faculty"),
      source = "faculty_roster_clean.csv") |>
    dplyr::distinct()
  record_roster_status(con, "graduate_faculty_status", "grad_id", grad,
                       "person_id", "is_graduate_faculty")
})

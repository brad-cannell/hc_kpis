# Update identities and explicit roster activity; never infer departure from
# absence. The approved name change keeps all references to the same person_id.
source("R/roster_helpers.R")

with_roster_db(function(con) {
  # Name uniqueness is checked here because DuckDB's secondary name index
  # prevents renaming a person with existing foreign-key references.
  duplicates <- DBI::dbGetQuery(con, "SELECT lower(trim(first_name)), lower(trim(last_name))
    FROM people GROUP BY 1, 2 HAVING count(*) > 1")
  if (nrow(duplicates)) stop("Duplicate normalized names in people; resolve before loading.")
  people <- read_roster("data/raw/faculty_roster_clean.csv") |>
    dplyr::transmute(first_name = given_name, last_name = family_name,
                    first_key = tolower(given_name), last_key = tolower(family_name)) |>
    dplyr::distinct()
  if (anyDuplicated(people[c("first_key", "last_key")])) {
    stop("Multiple spellings for the same person in the roster; review before loading.")
  }

  # Brad approved this surname change in the October 2026 roster review.
  # Fail if both identities already exist rather than merging unrelated rows.
  if (any(people$first_key == "alison" & people$last_key == "hoyer")) {
    if (any(people$first_key == "alison" & people$last_key == "prahl")) {
      stop("Roster contains both Alison Prahl and Alison Hoyer; resolve the duplicate first.")
    }
    aliases <- DBI::dbGetQuery(con, "SELECT person_id, lower(last_name) AS surname FROM people
      WHERE lower(trim(first_name)) = 'alison' AND lower(trim(last_name)) IN ('prahl', 'hoyer')")
    if (nrow(aliases) > 1L) stop("Both Alison Prahl and Alison Hoyer exist; resolve identity first.")
    DBI::dbExecute(con, "UPDATE people SET last_name = 'Hoyer'
      WHERE lower(trim(first_name)) = 'alison' AND lower(trim(last_name)) = 'prahl'")
  }

  # Explicit departures confirmed by Brad. Keeping these decisions here makes
  # this refresh reviewable; no appointment end dates are assigned. A later
  # roster that includes one of these people requires review of this decision.
  # Brad additionally reported Chris Watts died in January and Nada
  # Elias-Lambert left for Samuel Merritt University in December 2025 (per
  # LinkedIn). These reports establish inactivity, not exact effective dates.
  # Ashlie Seale remains unconfirmed: a LinkedIn listing alone was not accepted
  # as confirmation of a current faculty appointment in the October 2026 review.
  departed <- data.frame(first_key = c("dennis", "mary", "ashley", "chris", "nada"),
                         last_key = c("cheek", "twis", "franklin", "watts", "elias-lambert"))
  if (nrow(dplyr::inner_join(people, departed, by = c("first_key", "last_key")))) {
    stop("The roster includes a confirmed departure; review the activity decision.")
  }

  # Match by normalized names only for unchanged identities. No deletion or
  # blanket inactivity update is applied to people missing from this CSV.
  for (i in seq_len(nrow(people))) {
    row <- people[i, ]
    existing <- DBI::dbGetQuery(con, "SELECT person_id FROM people
      WHERE lower(trim(first_name)) = ? AND lower(trim(last_name)) = ?",
      params = list(row$first_key, row$last_key))
    if (nrow(existing) > 1L) stop("Duplicate normalized names in people.")
    if (nrow(existing) == 1L) {
      DBI::dbExecute(con, "UPDATE people SET first_name = ?, last_name = ?, is_active = TRUE WHERE person_id = ?",
        params = list(row$first_name, row$last_name, existing$person_id))
    } else {
      DBI::dbExecute(con, "INSERT INTO people (person_id, first_name, last_name, is_active) VALUES (?, ?, ?, TRUE)",
        params = list(uuid::UUIDgenerate(), row$first_name, row$last_name))
    }
  }
  for (i in seq_len(nrow(departed))) {
    DBI::dbExecute(con, "UPDATE people SET is_active = FALSE
      WHERE lower(trim(first_name)) = ? AND lower(trim(last_name)) = ?",
      params = list(departed$first_key[i], departed$last_key[i]))
  }
  message("People loaded; IDs retained and only explicit departures marked inactive.")
})

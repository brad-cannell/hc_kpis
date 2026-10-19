-- sql/01_people.sql
-- Core identity information for faculty (and possibly other people later).

CREATE TABLE IF NOT EXISTS people (
  person_id  TEXT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL,
  is_active BOOLEAN -- NULL means activity has not been reviewed.
);

-- The people loader validates normalized-name uniqueness transactionally.
-- A DuckDB secondary name index prevents a surname update on a person whose
-- ID is referenced by appointments. Identity remains protected by the PK/FKs.

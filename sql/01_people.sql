-- sql/01_people.sql
-- Core identity information for faculty (and possibly other people later).

CREATE TABLE IF NOT EXISTS people (
  person_id  TEXT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL
);

-- Prevent accidental duplicate person records caused by rerunning loaders.
-- We enforce uniqueness on normalized names (trim + lowercase).
CREATE UNIQUE INDEX IF NOT EXISTS uq_people_name_norm
  ON people (
    lower(trim(first_name)),
    lower(trim(last_name))
  );

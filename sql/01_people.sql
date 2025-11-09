-- sql/01_people.sql
-- Core identity information for faculty (and possibly other people later).

CREATE TABLE IF NOT EXISTS people (
  person_id  TEXT PRIMARY KEY,      -- UUID from R or another system
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL,
  email      TEXT,
  orcid      TEXT
);

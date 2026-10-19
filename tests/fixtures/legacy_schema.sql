-- Pre-change schema for migration regression tests. Never run on the working database.

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



CREATE TABLE IF NOT EXISTS tenure_status (
  tenure_id  TEXT PRIMARY KEY,
  person_id  TEXT NOT NULL,
  unit_code  TEXT NOT NULL,
  unit_name  TEXT,
  track      TEXT CHECK (track IN (
               'Tenured',
               'Tenure-Track',
               'Professional Practice'
             )),
  valid_from DATE NOT NULL,
  valid_to   DATE,
  source     TEXT,
  notes      TEXT,
  FOREIGN KEY (person_id) REFERENCES people(person_id)
);

CREATE INDEX IF NOT EXISTS idx_tenure_person
  ON tenure_status(person_id);
CREATE INDEX IF NOT EXISTS idx_tenure_unit
  ON tenure_status(unit_code);
CREATE INDEX IF NOT EXISTS idx_tenure_valid
  ON tenure_status(valid_from, valid_to);

CREATE TABLE IF NOT EXISTS graduate_faculty_status (
  grad_id             TEXT PRIMARY KEY,
  person_id           TEXT NOT NULL,
  is_graduate_faculty BOOLEAN NOT NULL DEFAULT FALSE,
  valid_from          DATE NOT NULL,
  valid_to            DATE,
  source              TEXT,
  notes               TEXT,
  FOREIGN KEY (person_id) REFERENCES people(person_id)
);

CREATE INDEX IF NOT EXISTS idx_grad_person
  ON graduate_faculty_status(person_id);
  
CREATE TABLE IF NOT EXISTS center_affiliations (
  affiliation_id TEXT PRIMARY KEY,
  person_id      TEXT NOT NULL,
  center_code    TEXT NOT NULL,
  center_name    TEXT,
  is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
  valid_from     DATE NOT NULL,
  valid_to       DATE,
  source         TEXT,
  notes          TEXT,
  FOREIGN KEY (person_id) REFERENCES people(person_id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE INDEX IF NOT EXISTS idx_center_aff_person
  ON center_affiliations(person_id);

CREATE INDEX IF NOT EXISTS idx_center_aff_center
  ON center_affiliations(center_code);

CREATE INDEX IF NOT EXISTS idx_center_aff_valid
  ON center_affiliations(valid_from, valid_to);

CREATE UNIQUE INDEX IF NOT EXISTS uq_center_aff_business_key
  ON center_affiliations(person_id, center_code, coalesce(center_name, ''), valid_from);

CREATE OR REPLACE VIEW v_current_tenure AS
SELECT *
FROM tenure_status
WHERE valid_from <= CURRENT_DATE
  AND (valid_to IS NULL OR valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_grad_faculty AS
SELECT *
FROM graduate_faculty_status
WHERE valid_from <= CURRENT_DATE
  AND (valid_to IS NULL OR valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_center_affiliations AS
SELECT *
FROM center_affiliations
WHERE valid_from <= CURRENT_DATE
  AND (valid_to IS NULL OR valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_faculty AS
SELECT
  p.person_id,
  p.first_name,
  p.last_name,
  t.unit_code,
  t.unit_name,
  t.track,
  g.is_graduate_faculty,
  c.center_code,
  c.center_name,
  c.is_primary AS is_primary_center_affiliation
FROM people p
LEFT JOIN v_current_tenure t
  ON p.person_id = t.person_id
LEFT JOIN v_current_grad_faculty g
  ON p.person_id = g.person_id
LEFT JOIN v_current_center_affiliations c
  ON p.person_id = c.person_id;



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

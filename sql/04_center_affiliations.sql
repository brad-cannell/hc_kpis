CREATE TABLE IF NOT EXISTS center_affiliations (
  affiliation_id TEXT PRIMARY KEY,
  person_id      TEXT NOT NULL,
  center_code    TEXT NOT NULL,
  center_name    TEXT,
  is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
  valid_from     DATE,
  valid_to       DATE,
  source         TEXT,
  notes          TEXT,
  is_current     BOOLEAN DEFAULT TRUE,
  recorded_on    DATE,
  FOREIGN KEY (person_id) REFERENCES people(person_id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE INDEX IF NOT EXISTS idx_center_aff_person
  ON center_affiliations(person_id);

CREATE INDEX IF NOT EXISTS idx_center_aff_center
  ON center_affiliations(center_code);

CREATE INDEX IF NOT EXISTS idx_center_aff_valid
  ON center_affiliations(valid_from, valid_to);

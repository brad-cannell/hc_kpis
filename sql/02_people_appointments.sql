-- sql/02_person_appointments.sql
-- Time-varying appointments (unit, rank, track, FTE, status) for each person.

CREATE TABLE IF NOT EXISTS person_appointments (
  appt_id     TEXT PRIMARY KEY,     -- UUID for the appointment record
  person_id   TEXT NOT NULL,        -- FK to people.person_id
  unit_code   TEXT NOT NULL,        -- e.g., APHS, KINE, NURS
  rank        TEXT,                 -- Assistant, Associate, Full, etc.
  track       TEXT,                 -- Tenure, Clinical/Practice, Research
  fte_share   DOUBLE,               -- 0.0–1.0 for this appointment
  status      TEXT,                 -- Active, On Leave, Emeritus, etc.
  valid_from  DATE NOT NULL,
  valid_to    DATE,                 -- NULL = ongoing
  source      TEXT,                 -- e.g., 'HR export', 'manual'
  notes       TEXT,
  FOREIGN KEY (person_id) REFERENCES people(person_id)
);

-- Helpful indexes for common queries
CREATE INDEX IF NOT EXISTS idx_appt_person
  ON person_appointments(person_id);

CREATE INDEX IF NOT EXISTS idx_appt_unit
  ON person_appointments(unit_code);

CREATE INDEX IF NOT EXISTS idx_appt_valid
  ON person_appointments(valid_from, valid_to);

CREATE TABLE IF NOT EXISTS graduate_faculty_status (
  grad_id             TEXT PRIMARY KEY,
  person_id           TEXT NOT NULL,
  is_graduate_faculty BOOLEAN,
  valid_from          DATE,
  valid_to            DATE,
  source              TEXT,
  notes               TEXT,
  is_current          BOOLEAN DEFAULT TRUE,
  recorded_on         DATE,
  FOREIGN KEY (person_id) REFERENCES people(person_id)
);

CREATE INDEX IF NOT EXISTS idx_grad_person
  ON graduate_faculty_status(person_id);

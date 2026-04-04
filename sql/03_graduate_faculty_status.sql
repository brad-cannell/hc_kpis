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
  
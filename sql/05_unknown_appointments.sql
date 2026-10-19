-- Preserve identity/history while allowing unknown dates and appointment values.
-- Run through data_01_duckdb_schema.R, which applies all DDL in one transaction.
-- NULL activity means unreviewed; only an explicit roster/decision sets it.
ALTER TABLE people ADD COLUMN IF NOT EXISTS is_active BOOLEAN;
-- Commit this removal with the migration before the people loader runs.
-- DuckDB cannot update an indexed surname while child rows reference the ID.
DROP INDEX IF EXISTS uq_people_name_norm;

-- DuckDB requires dependent indexes to be removed before relaxing constraints.
DROP VIEW IF EXISTS v_current_faculty;
DROP VIEW IF EXISTS v_current_tenure;
DROP VIEW IF EXISTS v_current_grad_faculty;
DROP VIEW IF EXISTS v_current_center_affiliations;
DROP INDEX IF EXISTS idx_tenure_person;
DROP INDEX IF EXISTS idx_tenure_unit;
DROP INDEX IF EXISTS idx_tenure_valid;
DROP INDEX IF EXISTS idx_grad_person;
DROP INDEX IF EXISTS idx_center_aff_person;
DROP INDEX IF EXISTS idx_center_aff_center;
DROP INDEX IF EXISTS idx_center_aff_valid;
DROP INDEX IF EXISTS uq_center_aff_business_key;

ALTER TABLE tenure_status ALTER COLUMN unit_code DROP NOT NULL;
ALTER TABLE tenure_status ALTER COLUMN valid_from DROP NOT NULL;
ALTER TABLE graduate_faculty_status ALTER COLUMN is_graduate_faculty DROP NOT NULL;
ALTER TABLE graduate_faculty_status ALTER COLUMN is_graduate_faculty DROP DEFAULT;
ALTER TABLE graduate_faculty_status ALTER COLUMN valid_from DROP NOT NULL;
ALTER TABLE center_affiliations ALTER COLUMN valid_from DROP NOT NULL;

-- is_current selects the latest recorded assertion, independently of when the
-- actual appointment began/ended. Never relabel recorded_on as an effective date.
-- Preserve every legacy effective date, including dates from earlier imports.
ALTER TABLE tenure_status ADD COLUMN IF NOT EXISTS is_current BOOLEAN;
ALTER TABLE tenure_status ADD COLUMN IF NOT EXISTS recorded_on DATE;
UPDATE tenure_status SET is_current = (valid_to IS NULL OR valid_to >= CURRENT_DATE)
WHERE is_current IS NULL;
ALTER TABLE tenure_status ALTER COLUMN is_current SET DEFAULT TRUE;
ALTER TABLE graduate_faculty_status ADD COLUMN IF NOT EXISTS is_current BOOLEAN;
ALTER TABLE graduate_faculty_status ADD COLUMN IF NOT EXISTS recorded_on DATE;
UPDATE graduate_faculty_status SET is_current = (valid_to IS NULL OR valid_to >= CURRENT_DATE)
WHERE is_current IS NULL;
ALTER TABLE graduate_faculty_status ALTER COLUMN is_current SET DEFAULT TRUE;
ALTER TABLE center_affiliations ADD COLUMN IF NOT EXISTS is_current BOOLEAN;
ALTER TABLE center_affiliations ADD COLUMN IF NOT EXISTS recorded_on DATE;
UPDATE center_affiliations SET is_current = (valid_to IS NULL OR valid_to >= CURRENT_DATE)
WHERE is_current IS NULL;
ALTER TABLE center_affiliations ALTER COLUMN is_current SET DEFAULT TRUE;

CREATE INDEX idx_tenure_person ON tenure_status(person_id);
CREATE INDEX idx_tenure_unit ON tenure_status(unit_code);
CREATE INDEX idx_tenure_valid ON tenure_status(valid_from, valid_to);
CREATE INDEX idx_grad_person ON graduate_faculty_status(person_id);
CREATE INDEX idx_center_aff_person ON center_affiliations(person_id);
CREATE INDEX idx_center_aff_center ON center_affiliations(center_code);
CREATE INDEX idx_center_aff_valid ON center_affiliations(valid_from, valid_to);
-- The former unique key included valid_from. It cannot identify observations
-- when effective dates are unknown; the loader checks current business keys.

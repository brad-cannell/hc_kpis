-- sql/views_01_current_faculty.sql
-- Views for current faculty and current appointments

-- Current appointments = time-valid and active
CREATE OR REPLACE VIEW v_current_appointments AS
SELECT
  appt_id,
  person_id,
  unit_code,
  rank,
  track,
  fte_share,
  status,
  valid_from,
  valid_to,
  source,
  notes
FROM person_appointments
WHERE
  valid_from <= CURRENT_DATE
  AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
  AND (status = 'Active' OR status IS NULL);

-- Current faculty = join people + current appointments
CREATE OR REPLACE VIEW v_current_faculty AS
SELECT
  p.person_id,
  p.first_name,
  p.last_name,
  p.email,
  p.orcid,
  a.appt_id,
  a.unit_code,
  a.rank,
  a.track,
  a.fte_share,
  a.status,
  a.valid_from,
  a.valid_to
FROM people p
JOIN v_current_appointments a
  ON p.person_id = a.person_id;

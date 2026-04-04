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

CREATE OR REPLACE VIEW v_current_faculty AS
SELECT
  p.person_id,
  p.first_name,
  p.last_name,
  t.unit_code,
  t.unit_name,
  t.track,
  g.is_graduate_faculty
FROM people p
LEFT JOIN v_current_tenure t
  ON p.person_id = t.person_id
LEFT JOIN v_current_grad_faculty g
  ON p.person_id = g.person_id;

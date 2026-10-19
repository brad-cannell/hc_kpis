-- Activity and appointment dates answer different questions. Inactive people
-- remain in all historical tables, but do not appear in current-faculty views.
CREATE OR REPLACE VIEW v_current_tenure AS
SELECT t.* FROM tenure_status t JOIN people p USING (person_id)
WHERE p.is_active IS TRUE AND t.is_current IS TRUE
  AND (t.valid_from IS NULL OR t.valid_from <= CURRENT_DATE)
  AND (t.valid_to IS NULL OR t.valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_grad_faculty AS
SELECT g.* FROM graduate_faculty_status g JOIN people p USING (person_id)
WHERE p.is_active IS TRUE AND g.is_current IS TRUE
  AND (g.valid_from IS NULL OR g.valid_from <= CURRENT_DATE)
  AND (g.valid_to IS NULL OR g.valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_center_affiliations AS
SELECT c.* FROM center_affiliations c JOIN people p USING (person_id)
WHERE p.is_active IS TRUE AND c.is_current IS TRUE
  AND (c.valid_from IS NULL OR c.valid_from <= CURRENT_DATE)
  AND (c.valid_to IS NULL OR c.valid_to >= CURRENT_DATE);

CREATE OR REPLACE VIEW v_current_faculty AS
SELECT p.person_id, p.first_name, p.last_name,
       t.unit_code, t.unit_name, t.track, g.is_graduate_faculty,
       c.center_code, c.center_name,
       c.is_primary AS is_primary_center_affiliation
FROM people p
LEFT JOIN v_current_tenure t USING (person_id)
LEFT JOIN v_current_grad_faculty g USING (person_id)
LEFT JOIN v_current_center_affiliations c USING (person_id)
WHERE p.is_active IS TRUE;

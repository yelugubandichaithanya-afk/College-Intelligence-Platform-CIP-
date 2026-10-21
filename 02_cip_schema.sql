-- =====================================================================
-- CIP Phase 1 - File 2 of 3: metric definitions (reference data)
-- Run AFTER 01_cip_schema.sql. Safe to re-run: it updates existing rows.
-- Tier A = evidence categories the brief should ATTEMPT to establish.
-- "Unable to Verify" is always a valid outcome and never invalidates an institution.
-- Tolerances are starting guesses; tune them after you have entered real data.
-- =====================================================================
begin;

insert into metric_definitions
  (metric_key, label, module, value_kind, unit, period_type, tier, is_sensitive, tolerance_abs, tolerance_pct, dimension_hint, description, sort_order)
values
-- Identity (the identifier crosswalk itself lives in institution_identifiers)
('management_type',              'Management type',                   'identity',      'text',    null,        'static',        'A', false, null, null, null,        'e.g. private unaided, government, aided. Use the source''s own wording.', 10),
('year_established',             'Year established',                  'identity',      'numeric', 'year',      'static',        'A', false, 0,    null, null,        null, 20),

-- Recognition and affiliation
('aicte_approval_status',        'AICTE approval status',             'accreditation', 'text',    null,        'annual',        'A', false, null, null, null,        'Approval status for the academic year, e.g. Approved.', 30),
('university_affiliation_status','University affiliation status',     'accreditation', 'text',    null,        'annual',        'A', false, null, null, null,        'Affiliation status granted by the affiliating university for the year.', 40),
('autonomous_status',            'Autonomous status',                 'accreditation', 'boolean', null,        'point_in_time', 'B', false, null, null, null,        null, 50),

-- Accreditation and ranking
('naac_grade',                   'NAAC grade',                        'accreditation', 'text',    null,        'point_in_time', 'A', false, null, null, null,        'Record the grade exactly as published (e.g. A++, A+).', 60),
('naac_valid_to',                'NAAC accreditation valid until',    'accreditation', 'date',    null,        'point_in_time', 'A', false, null, null, null,        null, 70),
('nba_accredited_programme',     'NBA-accredited programme',          'accreditation', 'boolean', null,        'point_in_time', 'B', false, null, null, 'Programme', 'One claim per programme. Dimension = programme name.', 80),
('nirf_participated',            'NIRF participation',                'accreditation', 'boolean', null,        'annual',        'B', false, null, null, 'Category',  null, 90),
('nirf_rank',                    'NIRF rank',                         'accreditation', 'numeric', 'rank',      'annual',        'B', false, 0,    null, 'Category',  'Dimension = NIRF category (e.g. Engineering, Overall).', 100),

-- Admissions (overall = empty dimension; branch level = dimension is the branch)
('approved_intake',              'Approved intake',                   'admissions',    'numeric', 'students',  'annual',        'A', false, 0,    null, 'Branch',    'Regulator-approved seats. Leave dimension empty for the overall figure.', 110),
('admitted_students',            'Students admitted',                 'admissions',    'numeric', 'students',  'annual',        'A', false, null, 1,    'Branch',    'First-year admissions. Leave dimension empty for the overall figure.', 120),
('total_enrolment',              'Total enrolment',                   'admissions',    'numeric', 'students',  'annual',        'A', false, null, 1,    null,        'All students across all years of study.', 130),

-- Placements (availability varies by institution; do not assume 5 complete years)
('students_eligible_placement',  'Students eligible for placement',   'placements',    'numeric', 'students',  'annual',        'A', false, null, 2,    'Branch',    'Note the source''s definition of eligible in notes.', 140),
('students_placed',              'Students placed',                   'placements',    'numeric', 'students',  'annual',        'A', false, null, 2,    'Branch',    'Note the source''s definition of placed in notes (offers vs students).', 150),
('median_package',               'Median package',                    'placements',    'numeric', 'INR LPA',   'annual',        'A', false, null, 5,    null,        'Source-dependent. Prefer independently published figures.', 160),
('highest_package',              'Highest package',                   'placements',    'numeric', 'INR LPA',   'annual',        'B', false, null, 10,   null,        'Marketing-prone. Institution-reported unless independently verified.', 170),

-- Fees (source-dependent)
('annual_tuition_fee',           'Annual tuition fee',                'fees',          'numeric', 'INR',       'annual',        'B', false, 0,    null, 'Programme', 'Regulated or approved fee where available.', 180),

-- Ownership / management (sensitive: full provenance required)
('management_role',              'Management role holder',            'ownership',     'text',    null,        'point_in_time', 'A', true,  null, null, 'Role',      'Dimension = role (e.g. Chairman). Value = name. Institutional capacity only.', 190),

-- Regulatory and legal events (sensitive: full provenance required)
('regulatory_action',            'Regulatory action',                 'risk',          'text',    null,        'event',         'A', true,  null, null, null,        'Short description. as_of_date = date of the action. Use claim_type to say what kind of statement this is.', 200),
('court_matter',                 'Court matter',                      'risk',          'text',    null,        'event',         'A', true,  null, null, null,        'Short description. as_of_date = date of the filing/order. A pending matter is never gating.', 210)
on conflict (metric_key) do update set
  label = excluded.label, module = excluded.module, value_kind = excluded.value_kind, unit = excluded.unit,
  period_type = excluded.period_type, tier = excluded.tier, is_sensitive = excluded.is_sensitive,
  tolerance_abs = excluded.tolerance_abs, tolerance_pct = excluded.tolerance_pct,
  dimension_hint = excluded.dimension_hint, description = excluded.description, sort_order = excluded.sort_order;

commit;

-- Quick check: expect 21 rows.
select count(*) as metric_count from metric_definitions;

-- =====================================================================
-- CIP Phase 1 - File 3: self-cleaning test suite (UPDATED for patch file 04)
-- Run AFTER files 1, 2 and 4. Safe to re-run: it replaces the older test function. This creates a test function; it does NOT run the tests.
-- To run the tests:   select * from cip_run_tests();
-- The tests build dummy data, check the rules, then roll everything back.
-- No test data is left behind in your database.
-- =====================================================================

create or replace function cip_test_result(p_no int, p_name text, p_ok boolean, p_detail text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('no', p_no, 'name', p_name,
                            'outcome', case when p_ok then 'PASS' else 'FAIL' end,
                            'detail', p_detail)
$$;

create or replace function cip_run_tests()
returns table (test_no int, test_name text, outcome text, detail text)
language plpgsql set search_path = public as $$
declare
  res jsonb := '[]'::jsonb;
  univ uuid; inst uuid; inst_b uuid;
  s_gov uuid; s_reg uuid; s_uni uuid; s_site uuid; s_media uuid;
  c_old uuid; c_alleg uuid; c_court uuid; c_action uuid;
  f_a uuid; f_c uuid; f_d uuid;
  org uuid; link1 uuid; link2 uuid; link_d uuid;
  n int; n2 int; ok boolean; txt text; txt2 text; txt3 text;
  r1 record; r2 record;
  n_pass int; n_fail int;
begin
  begin  -- everything in this block is rolled back at the end

    ------------------------------------------------------------------
    -- Fixtures
    ------------------------------------------------------------------
    insert into institutions (name, institution_type) values ('ZZ Test University', 'university') returning id into univ;
    insert into institutions (name, short_name, institution_type, affiliating_university_id, city, district, aliases)
      values ('ZZ Test College of Engineering', 'ZZTCE', 'college', univ, 'Hyderabad', 'Rangareddy', array['ZZ Old Name'])
      returning id into inst;
    insert into institutions (name, institution_type) values ('ZZ Other College', 'college') returning id into inst_b;

    insert into sources (title, publisher, url, authority, document_date) values ('Gov dataset', 'AISHE (test)', 'https://example.org/gov', 'government', '2025-01-10') returning id into s_gov;
    insert into sources (title, publisher, url, authority, document_date) values ('Regulator approval', 'AICTE (test)', 'https://example.org/reg', 'regulator', '2025-02-01') returning id into s_reg;
    insert into sources (title, publisher, url, authority, document_date) values ('University portal', 'Univ (test)', 'https://example.org/uni', 'university', '2025-03-01') returning id into s_uni;
    insert into sources (title, publisher, url, authority) values ('College website', 'College (test)', 'https://example.org/site', 'institution') returning id into s_site;
    insert into sources (title, publisher, url, authority) values ('News article', 'News (test)', 'https://example.org/news', 'media') returning id into s_media;

    -- Admissions evidence
    insert into claims (institution_id, metric_key, period_label, value_numeric, source_id, verification_status, workflow_status) values
      (inst, 'admitted_students', '2024-25', 950,  s_site, 'institution_reported', 'submitted'),
      (inst, 'admitted_students', '2024-25', 812,  s_uni,  'university_verified',  'submitted'),
      (inst, 'approved_intake',   '2024-25', 1000, s_reg,  'regulatory_verified',  'submitted'),
      (inst, 'admitted_students', '2023-24', 812,  s_uni,  'university_verified',  'submitted'),
      (inst, 'admitted_students', '2023-24', 815,  s_gov,  'government_verified',  'submitted'),
      (inst, 'admitted_students', '2022-23', 620,  s_uni,  'university_verified',  'submitted'),
      (inst, 'approved_intake',   '2022-23', 720,  s_reg,  'regulatory_verified',  'submitted');
    update claims set workflow_status = 'accepted' where institution_id = inst and workflow_status = 'submitted';

    ------------------------------------------------------------------
    -- Test 1: 950 vs 812 is a conflict and both numbers stay visible
    ------------------------------------------------------------------
    select count(*) into n from claim_groups
     where institution_id = inst and metric_key = 'admitted_students' and period_label = '2024-25' and is_conflicted;
    select count(*) into n2 from claims_display
     where institution_id = inst and metric_key = 'admitted_students' and period_label = '2024-25' and display_status = 'conflicting_sources';
    res := res || jsonb_build_array(cip_test_result(1, 'Conflict 950 vs 812 detected; both values visible', n = 1 and n2 = 2,
             format('conflict groups=%s (want 1); claims shown as Conflicting Sources=%s (want 2)', n, n2)));

    ------------------------------------------------------------------
    -- Test 2: 812 vs 815 is within tolerance
    ------------------------------------------------------------------
    select count(*) filter (where is_conflicted), count(*) into n, n2 from claim_groups
     where institution_id = inst and metric_key = 'admitted_students' and period_label = '2023-24';
    res := res || jsonb_build_array(cip_test_result(2, 'Tolerance: 812 vs 815 is NOT a conflict', n = 0 and n2 = 1,
             format('conflicted groups=%s (want 0) out of %s group(s) (want 1)', n, n2)));

    ------------------------------------------------------------------
    -- Test 3: Government Verified with an institution-website source is rejected
    ------------------------------------------------------------------
    begin
      insert into claims (institution_id, metric_key, period_label, value_numeric, source_id, verification_status, workflow_status)
        values (inst, 'approved_intake', '2021-22', 500, s_site, 'government_verified', 'submitted');
      res := res || jsonb_build_array(cip_test_result(3, 'Government Verified with a college-website source is rejected', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(3, 'Government Verified with a college-website source is rejected', sqlerrm like '%not allowed with%', sqlerrm));
    end;

    ------------------------------------------------------------------
    -- Test 4: an allegation can never make a flag gating
    ------------------------------------------------------------------
    insert into claims (institution_id, metric_key, as_of_date, value_text, source_id, locator, claim_type, verification_status, workflow_status)
      values (inst, 'regulatory_action', '2024-01-15', 'Alleged fee irregularity (test)', s_media, 'para 3', 'allegation', 'unable_to_verify', 'submitted')
      returning id into c_alleg;
    update claims set workflow_status = 'accepted' where id = c_alleg;
    insert into risk_flags (institution_id, title, category) values (inst, 'Test flag A', 'regulatory') returning id into f_a;
    insert into risk_flag_claims (risk_flag_id, claim_id) values (f_a, c_alleg);   -- linking is allowed on a non-gating flag
    begin
      update risk_flags set is_gating = true where id = f_a;
      res := res || jsonb_build_array(cip_test_result(4, 'Allegation cannot make a flag gating', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(4, 'Allegation cannot make a flag gating', sqlerrm like '%cannot make a flag gating%', sqlerrm));
    end;

    ------------------------------------------------------------------
    -- Test 5: derived seat utilisation lists its inputs and shows a range when conflicted
    ------------------------------------------------------------------
    select * into r1 from derived_seat_utilization where institution_id = inst and period_label = '2022-23';
    select * into r2 from derived_seat_utilization where institution_id = inst and period_label = '2024-25';
    ok := r1.value_low_pct = 86.1 and r1.value_high_pct = 86.1
          and jsonb_array_length(r1.inputs) = 2 and cardinality(r1.input_claim_ids) = 2
          and r1.derived_status = 'verified' and not r1.is_conflicted
          and r2.is_conflicted and r2.derived_status = 'conflicting_sources'
          and r2.value_low_pct = 81.2 and r2.value_high_pct = 95.0;
    res := res || jsonb_build_array(cip_test_result(5, 'Seat utilisation: inputs listed; range shown when an input is conflicted', coalesce(ok, false),
             format('2022-23: %s-%s%% status=%s inputs=%s | 2024-25: %s-%s%% status=%s',
                    r1.value_low_pct, r1.value_high_pct, r1.derived_status, jsonb_array_length(r1.inputs),
                    r2.value_low_pct, r2.value_high_pct, r2.derived_status)));

    ------------------------------------------------------------------
    -- Test 6: Unable to Verify is counted differently from Not Yet Researched
    ------------------------------------------------------------------
    begin
      insert into claims (institution_id, metric_key, period_label, verification_status, workflow_status)
        values (inst, 'median_package', '2024-25', 'unable_to_verify', 'submitted');   -- no value, no notes
      txt3 := 'No error was raised';
    exception when others then
      txt3 := sqlerrm;
    end;
    insert into claims (institution_id, metric_key, period_label, verification_status, workflow_status, notes)
      values (inst, 'median_package', '2024-25', 'unable_to_verify', 'submitted', 'Searched the college placement PDF; no median published');
    update claims set workflow_status = 'accepted' where institution_id = inst and metric_key = 'median_package';
    select coverage_status into txt  from institution_metric_coverage where institution_id = inst and metric_key = 'median_package';
    select coverage_status into txt2 from institution_metric_coverage where institution_id = inst and metric_key = 'highest_package';
    res := res || jsonb_build_array(cip_test_result(6, 'Unable to Verify differs from Not Yet Researched; a not-found record must say where you looked',
             txt = 'unable_to_verify' and txt2 = 'not_yet_researched' and txt3 like '%where you looked%',
             format('searched-but-not-found => %s (want unable_to_verify); never researched => %s (want not_yet_researched); no-notes error="%s"', txt, txt2, left(txt3, 60))));

    ------------------------------------------------------------------
    -- Test 7: superseding keeps history; only the latest version is current
    ------------------------------------------------------------------
    select id into c_old from claims where institution_id = inst and metric_key = 'admitted_students' and period_label = '2023-24' and value_numeric = 815;
    insert into claims (institution_id, metric_key, period_label, value_numeric, source_id, verification_status, workflow_status, supersedes_id)
      values (inst, 'admitted_students', '2023-24', 830, s_gov, 'government_verified', 'submitted', c_old);
    update claims set workflow_status = 'accepted' where institution_id = inst and value_numeric = 830;
    select count(*) into n from current_claims where institution_id = inst and metric_key = 'admitted_students' and period_label = '2023-24' and value_numeric = 815;
    select count(*) into n2 from claims where id = c_old;
    select is_conflicted into ok from claim_groups where institution_id = inst and metric_key = 'admitted_students' and period_label = '2023-24';
    res := res || jsonb_build_array(cip_test_result(7, 'Superseding: history preserved, only latest counts, conflict recomputed', n = 0 and n2 = 1 and ok,
             format('old value still current=%s (want 0); old row preserved=%s (want 1); conflict after correction=%s (want true)', n, n2, ok)));

    ------------------------------------------------------------------
    -- Test 9: a court matter (even a verified record of one) cannot make a flag gating
    ------------------------------------------------------------------
    insert into claims (institution_id, metric_key, as_of_date, value_text, source_id, locator, claim_type, verification_status, workflow_status)
      values (inst, 'court_matter', '2024-06-01', 'Pending writ petition (test)', s_gov, 'order p.1', 'court_matter', 'government_verified', 'submitted')
      returning id into c_court;
    update claims set workflow_status = 'accepted' where id = c_court;
    insert into risk_flags (institution_id, title, category) values (inst, 'Test flag C', 'legal') returning id into f_c;
    insert into risk_flag_claims (risk_flag_id, claim_id) values (f_c, c_court);
    begin
      update risk_flags set is_gating = true where id = f_c;
      res := res || jsonb_build_array(cip_test_result(9, 'Pending court matter cannot make a flag gating', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(9, 'Pending court matter cannot make a flag gating', sqlerrm like '%cannot make a flag gating%', sqlerrm));
    end;
    begin
      insert into risk_flags (institution_id, title, category, is_gating) values (inst, 'Gating with no evidence', 'legal', true);
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    res := res || jsonb_build_array(cip_test_result(9, 'A flag cannot be created as gating without linked evidence', txt like '%needs linked evidence%', txt));

    ------------------------------------------------------------------
    -- Test 10: a verified regulatory action CAN be gating; decisions require acknowledgement; versions count up
    ------------------------------------------------------------------
    insert into claims (institution_id, metric_key, as_of_date, value_text, source_id, locator, claim_type, verification_status, workflow_status)
      values (inst, 'regulatory_action', '2024-09-01', 'Show-cause notice (test)', s_reg, 'p.2', 'regulatory_action', 'regulatory_verified', 'submitted')
      returning id into c_action;
    update claims set workflow_status = 'accepted' where id = c_action;
    insert into risk_flags (institution_id, title, category, severity) values (inst, 'Test flag D', 'regulatory', 'high') returning id into f_d;
    insert into risk_flag_claims (risk_flag_id, claim_id) values (f_d, c_action);
    update risk_flags set is_gating = true where id = f_d;   -- must succeed
    select is_gating into ok from risk_flags where id = f_d;
    begin
      insert into assessments (institution_id, opportunity_rating, opportunity_rationale, risk_rating, risk_rationale, decision, priority, decision_rationale)
        values (inst, 'moderate', 'Test', 'high', 'Test', 'negotiate', 'medium', 'Test');
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    insert into assessments (institution_id, opportunity_rating, opportunity_rationale, risk_rating, risk_rationale, decision, priority, decision_rationale, acknowledged_flag_ids)
      values (inst, 'moderate', 'Test', 'high', 'Test', 'negotiate', 'medium', 'Test', array[f_d]);
    insert into assessments (institution_id, opportunity_rating, opportunity_rationale, risk_rating, risk_rationale, decision, priority, decision_rationale, acknowledged_flag_ids)
      values (inst, 'moderate', 'Test 2', 'high', 'Test 2', 'pursue', 'low', 'Test 2', array[f_d]);
    select count(*), max(version) into n, n2 from assessments where institution_id = inst;
    res := res || jsonb_build_array(cip_test_result(10, 'Verified regulatory action can be gating; decision needs acknowledgement; versions increment',
             ok and txt like '%Acknowledge every open gating flag%' and n = 2 and n2 = 2,
             format('flag became gating=%s; unacknowledged decision error="%s"; assessments=%s, latest version=%s', ok, left(txt, 60), n, n2)));

    ------------------------------------------------------------------
    -- Test 11: claims cannot be edited after submission
    ------------------------------------------------------------------
    begin
      update claims set value_numeric = 1 where id = c_old;
      res := res || jsonb_build_array(cip_test_result(11, 'Claims cannot be edited after acceptance', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(11, 'Claims cannot be edited after acceptance', sqlerrm like '%cannot be edited after submission%', sqlerrm));
    end;

    ------------------------------------------------------------------
    -- Test 12: assessments are append-only
    ------------------------------------------------------------------
    begin
      update assessments set decision_rationale = 'tampered' where institution_id = inst;
      res := res || jsonb_build_array(cip_test_result(12, 'Assessments cannot be changed or deleted', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(12, 'Assessments cannot be changed or deleted', sqlerrm like '%append-only%', sqlerrm));
    end;

    ------------------------------------------------------------------
    -- Test 13: a sensitive claim without a locator/excerpt is rejected
    ------------------------------------------------------------------
    begin
      insert into claims (institution_id, metric_key, as_of_date, value_text, source_id, claim_type, verification_status, workflow_status)
        values (inst, 'regulatory_action', '2024-02-02', 'Notice without locator (test)', s_reg, 'regulatory_action', 'regulatory_verified', 'submitted');
      res := res || jsonb_build_array(cip_test_result(13, 'Sensitive claim without locator/excerpt is rejected', false, 'No error was raised'));
    exception when others then
      res := res || jsonb_build_array(cip_test_result(13, 'Sensitive claim without locator/excerpt is rejected', sqlerrm like '%locator%', sqlerrm));
    end;

    ------------------------------------------------------------------
    -- Test 14: a media source can never carry a verified status (but Unable to Verify is fine)
    ------------------------------------------------------------------
    begin
      insert into claims (institution_id, metric_key, period_label, value_numeric, source_id, verification_status, workflow_status)
        values (inst, 'admitted_students', '2021-22', 400, s_media, 'government_verified', 'submitted');
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    begin
      insert into claims (institution_id, metric_key, period_label, value_numeric, source_id, verification_status, workflow_status)
        values (inst, 'admitted_students', '2021-22', 400, s_media, 'unable_to_verify', 'submitted');
      ok := true;
    exception when others then
      ok := false;
    end;
    res := res || jsonb_build_array(cip_test_result(14, 'Media source cannot carry a verified status; Unable to Verify is allowed',
             txt like '%not allowed with a media source%' and ok,
             format('verified+media error="%s"; unable_to_verify+media accepted=%s', txt, ok)));

    ------------------------------------------------------------------
    -- Test 15: search by short name, identifier code, promoter and university
    ------------------------------------------------------------------
    insert into institution_identifiers (institution_id, scheme, identifier_value, source_id, verification_status)
      values (inst, 'AISHE', 'C-99999', s_gov, 'government_verified');
    insert into organisations (name, org_type) values ('ZZ Test Educational Trust', 'trust') returning id into org;
    insert into institution_organisations (institution_id, organisation_id, relationship, source_id, verification_status, workflow_status)
      values (inst, org, 'owner', s_site, 'institution_reported', 'submitted') returning id into link1;
    update institution_organisations set workflow_status = 'accepted' where id = link1;
    ok := exists (select 1 from search_institutions('ZZTCE') where id = inst)
      and exists (select 1 from search_institutions('c-99999') where id = inst)
      and exists (select 1 from search_institutions('ZZ Test Educational Trust') where id = inst)
      and exists (select 1 from search_institutions('ZZ Test University') where id = inst)
      and exists (select 1 from search_institutions('ZZ Old Name') where id = inst);
    res := res || jsonb_build_array(cip_test_result(15, 'Search finds an institution by short name, AISHE code, promoter, university and alias', ok, 'all five lookups must find the test college'));

    ------------------------------------------------------------------
    -- Test 16: the same identifier cannot belong to two institutions; status must match source
    ------------------------------------------------------------------
    begin
      insert into institution_identifiers (institution_id, scheme, identifier_value, source_id, verification_status)
        values (inst_b, 'AISHE', 'c-99999', s_gov, 'government_verified');
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    begin
      insert into institution_identifiers (institution_id, scheme, identifier_value, source_id, verification_status)
        values (inst_b, 'AICTE', '1-ZZ', s_site, 'government_verified');
      txt2 := 'No error was raised';
    exception when others then
      txt2 := sqlerrm;
    end;
    res := res || jsonb_build_array(cip_test_result(16, 'Duplicate identifier blocked; identifier status must match its source',
             txt like '%uq_identifier_scheme_value%' and txt2 like '%not allowed with%',
             format('duplicate: %s | status mismatch: %s', left(txt, 70), left(txt2, 70))));

    ------------------------------------------------------------------
    -- Test 17: ownership links follow the draft -> submitted -> accepted review flow
    ------------------------------------------------------------------
    insert into institution_organisations (institution_id, organisation_id, relationship, source_id, verification_status)
      values (inst_b, org, 'sponsor', s_site, 'institution_reported') returning id into link_d;   -- defaults to draft
    begin
      update institution_organisations set workflow_status = 'accepted' where id = link_d;
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    update institution_organisations set workflow_status = 'submitted' where id = link_d;
    begin
      update institution_organisations set notes = 'edited after submission' where id = link_d;
      txt2 := 'No error was raised';
    exception when others then
      txt2 := sqlerrm;
    end;
    update institution_organisations set workflow_status = 'accepted' where id = link_d;
    select workflow_status::text into txt3 from institution_organisations where id = link_d;
    res := res || jsonb_build_array(cip_test_result(17, 'Ownership link: draft cannot skip submission; no edits after submission; can then be accepted',
             txt like '%must be submitted%' and txt2 like '%cannot be edited after submission%' and txt3 = 'accepted',
             format('draft->accepted: "%s" | edit after submit: "%s" | final status=%s', left(txt, 50), left(txt2, 50), txt3)));

    ------------------------------------------------------------------
    -- Test 18: ownership corrections supersede; duplicates are blocked
    ------------------------------------------------------------------
    insert into institution_organisations (institution_id, organisation_id, relationship, source_id, verification_status, workflow_status, supersedes_id)
      values (inst, org, 'owner', s_site, 'institution_reported', 'submitted', link1) returning id into link2;
    update institution_organisations set workflow_status = 'accepted' where id = link2;
    select count(*), bool_and(id = link2) into n, ok from current_institution_organisations
     where institution_id = inst and organisation_id = org and relationship = 'owner';
    select count(*) into n2 from institution_organisations where id = link1;
    begin
      insert into institution_organisations (institution_id, organisation_id, relationship, source_id, verification_status, workflow_status)
        values (inst, org, 'owner', s_site, 'institution_reported', 'submitted');
      txt := 'No error was raised';
    exception when others then
      txt := sqlerrm;
    end;
    res := res || jsonb_build_array(cip_test_result(18, 'Ownership correction supersedes the old link (history kept); duplicate current link blocked',
             n = 1 and ok and n2 = 1 and txt like '%already has a current or pending%',
             format('current links=%s (want 1), is the correction=%s; old row kept=%s (want 1); duplicate error="%s"', n, ok, n2, left(txt, 60))));

    ------------------------------------------------------------------
    -- Test 19: identifier codes appear in the coverage checklist
    ------------------------------------------------------------------
    select coverage_status into txt  from institution_metric_coverage where institution_id = inst and metric_key = 'identifier_aishe';
    select coverage_status into txt2 from institution_metric_coverage where institution_id = inst and metric_key = 'identifier_aicte';
    select count(*) into n from institution_metric_coverage where institution_id = univ and metric_key = 'identifier_aicte';
    insert into institution_identifiers (institution_id, scheme, identifier_value, source_id, verification_status)
      values (inst, 'AISHE', 'C-11111', s_site, 'institution_reported');
    select coverage_status into txt3 from institution_metric_coverage where institution_id = inst and metric_key = 'identifier_aishe';
    res := res || jsonb_build_array(cip_test_result(19, 'Identifier coverage: established / not yet researched / college-only AICTE / conflicting codes',
             txt = 'established' and txt2 = 'not_yet_researched' and n = 0 and txt3 = 'conflicted',
             format('AISHE=%s (want established); AICTE=%s (want not_yet_researched); AICTE rows for a university=%s (want 0); after a second different AISHE code=%s (want conflicted)', txt, txt2, n, txt3)));

    raise exception 'cip_rollback';   -- undo every test row
  exception when others then
    if sqlerrm <> 'cip_rollback' then
      res := res || jsonb_build_array(cip_test_result(0, 'TEST RUN CRASHED (this is a bug in the test or schema)', false, sqlerrm));
    end if;
  end;

  select count(*) filter (where r ->> 'outcome' = 'PASS'), count(*) filter (where r ->> 'outcome' = 'FAIL')
    into n_pass, n_fail from jsonb_array_elements(res) r;
  res := res || jsonb_build_array(cip_test_result(99, format('SUMMARY: %s passed, %s failed (test 8 is the manual logged-out check)', n_pass, n_fail), n_fail = 0, ''));

  return query
    select (t.r ->> 'no')::int, t.r ->> 'name', t.r ->> 'outcome', t.r ->> 'detail'
      from jsonb_array_elements(res) with ordinality as t(r, ord)
     order by (t.r ->> 'no')::int, t.ord;
end $$;

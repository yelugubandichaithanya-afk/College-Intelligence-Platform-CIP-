-- =====================================================================
-- CIP Phase 1b patch (file 4)
-- Run AFTER files 01 and 02 (and after the first run of 03).
-- Implements Section 10 decisions #6 and #8:
--   #6  Ownership links get the same draft -> submitted -> accepted review flow as claims
--   #8  Identifier codes (AISHE, AICTE, NAAC, NIRF) appear in the coverage checklist
-- One transaction: if anything fails, nothing is changed.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- #6  Review workflow for ownership links
-- ---------------------------------------------------------------------
alter table institution_organisations
  add column workflow_status workflow_status not null default 'draft',
  add column supersedes_id   uuid references institution_organisations(id) on delete restrict,
  add column reviewed_by     uuid references auth.users(id) on delete set null,
  add column reviewed_at     timestamptz,
  add column submitted_at    timestamptz,
  add constraint inst_org_no_self_supersede check (supersedes_id is null or supersedes_id <> id);

-- Any link that existed before this patch was already live, so keep it live.
update institution_organisations set workflow_status = 'accepted', reviewed_at = now();

-- The old "one row per institution+organisation+relationship" rule would block corrections.
-- The trigger below enforces the same idea in a correction-friendly way.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.institution_organisations'::regclass and contype = 'u';
  if c is not null then
    execute format('alter table institution_organisations drop constraint %I', c);
  end if;
end $$;

create or replace function cip_check_inst_org() returns trigger
language plpgsql set search_path = public as $$
declare
  prior institution_organisations%rowtype;
begin
  perform cip_check_status_vs_source(new.verification_status, new.source_id, 'An ownership link');

  if tg_op = 'INSERT' and new.workflow_status not in ('draft', 'submitted') then
    raise exception 'New ownership links must start as draft or submitted.';
  end if;
  if tg_op = 'UPDATE' and old.workflow_status = 'draft'
     and new.workflow_status in ('accepted', 'rejected') then
    raise exception 'A draft must be submitted before it can be accepted or rejected.';
  end if;

  if tg_op = 'UPDATE' and old.workflow_status <> 'draft' then
    if (to_jsonb(new) - 'workflow_status' - 'reviewed_by' - 'reviewed_at' - 'submitted_at')
       is distinct from
       (to_jsonb(old) - 'workflow_status' - 'reviewed_by' - 'reviewed_at' - 'submitted_at') then
      raise exception 'Ownership links cannot be edited after submission. Record a correction as a new link that supersedes this one.';
    end if;
    if old.workflow_status in ('accepted', 'rejected') and new.workflow_status <> old.workflow_status then
      raise exception 'An accepted or rejected ownership link cannot change status.';
    end if;
  end if;

  if new.workflow_status = 'submitted' and (tg_op = 'INSERT' or old.workflow_status is distinct from 'submitted') then
    new.submitted_at := now();
  end if;
  if new.workflow_status in ('accepted', 'rejected')
     and (tg_op = 'INSERT' or old.workflow_status is distinct from new.workflow_status) then
    new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    new.reviewed_at := coalesce(new.reviewed_at, now());
  end if;

  if new.workflow_status in ('draft', 'rejected') then
    return new;
  end if;

  if new.supersedes_id is not null then
    select * into prior from institution_organisations where id = new.supersedes_id;
    if prior.institution_id <> new.institution_id
       or prior.organisation_id <> new.organisation_id
       or prior.relationship <> new.relationship then
      raise exception 'A correction must be for the same institution, organisation and relationship as the link it supersedes.';
    end if;
    if prior.workflow_status <> 'accepted' then
      raise exception 'Only an accepted ownership link can be superseded.';
    end if;
  end if;

  if exists (
    select 1 from institution_organisations o
     where o.institution_id  = new.institution_id
       and o.organisation_id = new.organisation_id
       and o.relationship    = new.relationship
       and o.id <> new.id
       and o.workflow_status in ('submitted', 'accepted')
       and o.id is distinct from new.supersedes_id
       and not exists (select 1 from institution_organisations n
                        where n.supersedes_id = o.id and n.workflow_status = 'accepted')
  ) then
    raise exception 'This institution already has a current or pending % link with this organisation. Submit a correction that supersedes it instead.', new.relationship;
  end if;

  return new;
end $$;

-- Only drafts can be deleted from the app.
drop policy "authenticated delete" on institution_organisations;
create policy "authenticated delete drafts" on institution_organisations
  for delete to authenticated using (workflow_status = 'draft');

-- "Current" ownership = accepted and not replaced by a later accepted correction.
create view current_institution_organisations with (security_invoker = true) as
select o.*
  from institution_organisations o
 where o.workflow_status = 'accepted'
   and not exists (select 1 from institution_organisations n
                    where n.supersedes_id = o.id and n.workflow_status = 'accepted');

-- Promoter search should only follow reviewed (accepted, current) ownership links.
create or replace function search_institutions(q text default null) returns setof institutions
language sql stable security invoker set search_path = public as $$
  select distinct i.*
    from institutions i
    left join institutions u on u.id = i.affiliating_university_id
    left join institution_identifiers ii on ii.institution_id = i.id
    left join current_institution_organisations io on io.institution_id = i.id
    left join organisations o on o.id = io.organisation_id
   where q is null or btrim(q) = ''
      or i.name       ilike '%' || btrim(q) || '%'
      or i.short_name ilike '%' || btrim(q) || '%'
      or i.city       ilike '%' || btrim(q) || '%'
      or i.district   ilike '%' || btrim(q) || '%'
      or u.name       ilike '%' || btrim(q) || '%'
      or ii.identifier_value ilike '%' || btrim(q) || '%'
      or o.name       ilike '%' || btrim(q) || '%'
      or exists (select 1 from unnest(i.aliases) a where a ilike '%' || btrim(q) || '%')
   order by i.name
$$;

-- ---------------------------------------------------------------------
-- #8  Identifier codes in the coverage checklist
--     Expected codes: AISHE and AICTE (Tier A; AICTE for colleges only),
--     NAAC and NIRF (Tier B). Edit the VALUES list below to change this.
-- ---------------------------------------------------------------------
drop view institution_metric_coverage;

create view institution_metric_coverage with (security_invoker = true) as
with cur as (
  select institution_id, metric_key,
         count(*) as n_current_claims,
         count(*) filter (where verification_status in ('government_verified', 'university_verified', 'regulatory_verified')) as n_verified,
         count(*) filter (where verification_status = 'institution_reported') as n_institution_reported,
         count(distinct coalesce(period_label, '')) as n_periods
    from current_claims group by institution_id, metric_key
), conf as (
  select institution_id, metric_key, count(*) as n_conflicts
    from claim_groups where is_conflicted group by institution_id, metric_key
), pend as (
  select institution_id, metric_key, count(*) as n_pending
    from claims where workflow_status in ('draft', 'submitted') group by institution_id, metric_key
)
select
  i.id as institution_id, m.metric_key, m.label, m.module, m.tier, m.period_type,
  coalesce(cur.n_current_claims, 0) as n_current_claims,
  coalesce(cur.n_periods, 0)        as n_periods,
  coalesce(conf.n_conflicts, 0)     as n_conflicts,
  coalesce(pend.n_pending, 0)       as n_pending,
  case
    when coalesce(conf.n_conflicts, 0) > 0           then 'conflicted'
    when coalesce(cur.n_verified, 0) > 0             then 'established'
    when coalesce(cur.n_institution_reported, 0) > 0 then 'institution_reported_only'
    when coalesce(cur.n_current_claims, 0) > 0       then 'unable_to_verify'
    when coalesce(pend.n_pending, 0) > 0             then 'pending_review'
    else 'not_yet_researched'
  end as coverage_status
  from institutions i
 cross join metric_definitions m
  left join cur  on cur.institution_id  = i.id and cur.metric_key  = m.metric_key
  left join conf on conf.institution_id = i.id and conf.metric_key = m.metric_key
  left join pend on pend.institution_id = i.id and pend.metric_key = m.metric_key
 where m.is_active

union all

select
  i.id,
  ('identifier_' || lower(sch.scheme))::text,
  sch.label::text,
  'identity'::text,
  sch.tier,
  'static'::period_type,
  count(ii.id)::bigint,
  0::bigint,
  (case when count(distinct lower(btrim(ii.identifier_value))) > 1 then 1 else 0 end)::bigint,
  0::bigint,
  case
    when count(distinct lower(btrim(ii.identifier_value))) > 1 then 'conflicted'
    when count(*) filter (where ii.verification_status in ('government_verified', 'university_verified', 'regulatory_verified')) > 0 then 'established'
    when count(*) filter (where ii.verification_status = 'institution_reported') > 0 then 'institution_reported_only'
    when count(ii.id) > 0 then 'unable_to_verify'
    else 'not_yet_researched'
  end
  from institutions i
  join (values
         ('AISHE', 'AISHE code', 'A'::metric_tier, true),
         ('AICTE', 'AICTE ID',   'A'::metric_tier, false),
         ('NAAC',  'NAAC ID',    'B'::metric_tier, true),
         ('NIRF',  'NIRF ID',    'B'::metric_tier, true)
       ) as sch(scheme, label, tier, applies_to_universities)
    on (i.institution_type = 'college' or sch.applies_to_universities)
  left join institution_identifiers ii on ii.institution_id = i.id and ii.scheme = sch.scheme
 group by i.id, sch.scheme, sch.label, sch.tier;

-- Access (same rules as before)
revoke all on all tables in schema public from anon;
grant select on current_institution_organisations, institution_metric_coverage to authenticated;

commit;

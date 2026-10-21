-- =====================================================================
-- CIP (College Intelligence Platform) - Phase 1 schema
-- File 1 of 3. Run once, in the Supabase SQL Editor, on an EMPTY project.
-- The whole script is one transaction: if anything fails, nothing is created.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Allowed values (enums)
-- ---------------------------------------------------------------------
create type institution_type    as enum ('college', 'university');
create type claim_type          as enum ('fact', 'allegation', 'regulatory_action', 'court_matter', 'verified_outcome');
create type verification_status as enum ('government_verified', 'university_verified', 'regulatory_verified', 'institution_reported', 'unable_to_verify');
create type workflow_status     as enum ('draft', 'submitted', 'accepted', 'rejected');
create type source_authority    as enum ('government', 'regulator', 'university', 'institution', 'third_party', 'media');
create type value_kind          as enum ('numeric', 'text', 'date', 'boolean');
create type period_type         as enum ('annual', 'point_in_time', 'event', 'static');
create type metric_tier         as enum ('A', 'B', 'C');
create type rating_level        as enum ('low', 'moderate', 'high', 'unclear');
create type decision_type       as enum ('pursue', 'prioritize', 'negotiate', 'do_not_pursue');
create type priority_tier       as enum ('high', 'medium', 'low');
create type flag_severity       as enum ('low', 'medium', 'high');
create type flag_status         as enum ('open', 'resolved', 'dismissed');

-- NOTE: "Conflicting Sources" is deliberately NOT a stored verification status.
-- It is computed by the claim_groups / claims_display views.

-- ---------------------------------------------------------------------
-- 2. Small helper functions
-- ---------------------------------------------------------------------
create function cip_touch_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

create function cip_block_mutation() returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception '% is append-only: rows cannot be changed or deleted. Record a new version instead.', tg_table_name;
end $$;

-- ---------------------------------------------------------------------
-- 3. Identity: institutions
--    Only navigation fields live here. Anything that needs evidence
--    (management type, affiliation status, etc.) is a CLAIM.
-- ---------------------------------------------------------------------
create table institutions (
  id                        uuid primary key default gen_random_uuid(),
  name                      text not null check (btrim(name) <> ''),
  short_name                text,
  institution_type          institution_type not null default 'college',
  affiliating_university_id uuid references institutions(id) on delete restrict,
  district                  text,
  city                      text,
  state                     text not null default 'Telangana',
  aliases                   text[] not null default '{}',
  notes                     text,
  created_by                uuid references auth.users(id) on delete set null default auth.uid(),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (affiliating_university_id is null or affiliating_university_id <> id)
);
comment on table institutions is 'Master record. Navigation fields only; evidence lives in claims.';
comment on column institutions.affiliating_university_id is 'Navigation link only. The EVIDENCE for affiliation is the university_affiliation_status claim.';

create function cip_check_affiliating_university() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.affiliating_university_id is not null
     and not exists (select 1 from institutions u
                     where u.id = new.affiliating_university_id and u.institution_type = 'university') then
    raise exception 'affiliating_university_id must point to an institution of type university.';
  end if;
  return new;
end $$;

create trigger trg_institutions_check_parent before insert or update on institutions
  for each row execute function cip_check_affiliating_university();
create trigger trg_institutions_touch before update on institutions
  for each row execute function cip_touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Sources
-- ---------------------------------------------------------------------
create table sources (
  id               uuid primary key default gen_random_uuid(),
  title            text not null check (btrim(title) <> ''),
  publisher        text not null check (btrim(publisher) <> ''),
  url              text,
  authority        source_authority not null,
  doc_type         text not null default 'web_page'
                   check (doc_type in ('web_page', 'pdf', 'dataset', 'portal_record', 'court_record', 'news_article', 'other')),
  document_date    date,
  retrieved_on     date not null default current_date,
  stored_file_path text,
  notes            text,
  created_by       uuid references auth.users(id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (url is not null or stored_file_path is not null)
);
comment on column sources.authority is 'Who published it. Decides which verification statuses a claim may carry.';
comment on column sources.stored_file_path is 'Only set when a file is uploaded to Storage. Links are preferred (free-tier storage).';

create trigger trg_sources_touch before update on sources
  for each row execute function cip_touch_updated_at();

-- ---------------------------------------------------------------------
-- 5. Shared rule: a verification status must be consistent with the source
-- ---------------------------------------------------------------------
create function cip_check_status_vs_source(p_status verification_status, p_source uuid, p_label text)
returns void language plpgsql set search_path = public as $$
declare
  a source_authority;
begin
  if p_status = 'unable_to_verify' then
    return;
  end if;
  if p_source is null then
    raise exception '% needs a source before it can have status %.', p_label, p_status;
  end if;
  select authority into a from sources where id = p_source;
  if not found then
    raise exception '% refers to a source that does not exist.', p_label;
  end if;
  if (p_status = 'government_verified'  and a <> 'government')
  or (p_status = 'regulatory_verified'  and a <> 'regulator')
  or (p_status = 'university_verified'  and a <> 'university')
  or (p_status = 'institution_reported' and a <> 'institution') then
    raise exception 'Status % is not allowed with a % source.', p_status, a;
  end if;
end $$;

-- A source's authority cannot be changed once evidence depends on it.
-- (Claims and identifiers are created below; this trigger is attached after they exist.)
create function cip_guard_source_authority() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.authority is distinct from old.authority and (
       exists (select 1 from claims c where c.source_id = old.id and c.workflow_status in ('submitted', 'accepted'))
    or exists (select 1 from institution_identifiers i where i.source_id = old.id)
    or exists (select 1 from institution_organisations o where o.source_id = old.id)
  ) then
    raise exception 'Cannot change the authority of a source that existing evidence depends on.';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 6. Identity crosswalk (AISHE, AICTE, NAAC, NIRF ... codes)
-- ---------------------------------------------------------------------
create table institution_identifiers (
  id                  uuid primary key default gen_random_uuid(),
  institution_id      uuid not null references institutions(id) on delete restrict,
  scheme              text not null check (scheme in ('AISHE', 'AICTE', 'NAAC', 'NBA', 'NIRF', 'UNIVERSITY', 'ADMISSIONS_AUTHORITY', 'OTHER')),
  identifier_value    text not null check (btrim(identifier_value) <> ''),
  source_id           uuid not null references sources(id) on delete restrict,
  verification_status verification_status not null,
  locator             text,
  notes               text,
  created_by          uuid references auth.users(id) on delete set null default auth.uid(),
  created_at          timestamptz not null default now()
);
-- The same code can never point at two different institutions.
create unique index uq_identifier_scheme_value
  on institution_identifiers (scheme, lower(btrim(identifier_value)));
create index idx_identifiers_institution on institution_identifiers (institution_id);

create function cip_check_identifier() returns trigger
language plpgsql set search_path = public as $$
begin
  perform cip_check_status_vs_source(new.verification_status, new.source_id, 'An identifier');
  return new;
end $$;
create trigger trg_identifiers_check before insert or update on institution_identifiers
  for each row execute function cip_check_identifier();

-- ---------------------------------------------------------------------
-- 7. Ownership: organisations and their links to institutions
-- ---------------------------------------------------------------------
create table organisations (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (btrim(name) <> ''),
  org_type            text not null default 'other' check (org_type in ('trust', 'society', 'company', 'other')),
  registration_number text,
  notes               text,
  created_by          uuid references auth.users(id) on delete set null default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table organisations is 'Identity only. The claim that an organisation owns an institution lives in institution_organisations, with its own source.';
create trigger trg_organisations_touch before update on organisations
  for each row execute function cip_touch_updated_at();

create table institution_organisations (
  id                  uuid primary key default gen_random_uuid(),
  institution_id      uuid not null references institutions(id) on delete restrict,
  organisation_id     uuid not null references organisations(id) on delete restrict,
  relationship        text not null check (relationship in ('owner', 'sponsor', 'managing_body', 'related')),
  source_id           uuid not null references sources(id) on delete restrict,
  verification_status verification_status not null,
  as_of_date          date,
  locator             text,
  excerpt             text check (excerpt is null or char_length(excerpt) <= 600),
  notes               text,
  created_by          uuid references auth.users(id) on delete set null default auth.uid(),
  created_at          timestamptz not null default now(),
  unique (institution_id, organisation_id, relationship)
);
create index idx_inst_org_org on institution_organisations (organisation_id);

create function cip_check_inst_org() returns trigger
language plpgsql set search_path = public as $$
begin
  perform cip_check_status_vs_source(new.verification_status, new.source_id, 'An ownership link');
  return new;
end $$;
create trigger trg_inst_org_check before insert or update on institution_organisations
  for each row execute function cip_check_inst_org();

-- ---------------------------------------------------------------------
-- 8. Metric definitions (reference data: what can be recorded, and how)
-- ---------------------------------------------------------------------
create table metric_definitions (
  metric_key     text primary key check (metric_key ~ '^[a-z][a-z0-9_]*$'),
  label          text not null,
  module         text not null,
  value_kind     value_kind not null,
  unit           text,
  period_type    period_type not null,
  tier           metric_tier not null,
  is_sensitive   boolean not null default false,
  tolerance_abs  numeric check (tolerance_abs is null or tolerance_abs >= 0),
  tolerance_pct  numeric check (tolerance_pct is null or tolerance_pct >= 0),
  dimension_hint text,
  description    text,
  sort_order     int not null default 100,
  is_active      boolean not null default true
);
comment on column metric_definitions.tolerance_abs is 'Numeric metrics: differences up to this amount are NOT a conflict.';
comment on column metric_definitions.tolerance_pct is 'Numeric metrics: differences up to this % of the larger value are NOT a conflict.';

-- ---------------------------------------------------------------------
-- 9. Claims: the evidence core
-- ---------------------------------------------------------------------
create table claims (
  id                  uuid primary key default gen_random_uuid(),
  institution_id      uuid not null references institutions(id) on delete restrict,
  metric_key          text not null references metric_definitions(metric_key) on delete restrict,
  period_label        text check (
                        period_label is null or
                        case when period_label ~ '^[0-9]{4}-[0-9]{2}$'
                             then right(period_label, 2)::int = (left(period_label, 4)::int + 1) % 100
                             else false end),
  period_start_year   int generated always as (case when period_label is null then null else left(period_label, 4)::int end) stored,
  as_of_date          date,
  dimension           text not null default '',
  value_numeric       numeric,
  value_text          text,
  value_date          date,
  value_boolean       boolean,
  source_id           uuid references sources(id) on delete restrict,
  locator             text,
  excerpt             text check (excerpt is null or char_length(excerpt) <= 600),
  notes               text,
  claim_type          claim_type not null default 'fact',
  verification_status verification_status not null default 'unable_to_verify',
  workflow_status     workflow_status not null default 'draft',
  supersedes_id       uuid references claims(id) on delete restrict,
  entered_by          uuid references auth.users(id) on delete set null default auth.uid(),
  reviewed_by         uuid references auth.users(id) on delete set null,
  reviewed_at         timestamptz,
  submitted_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (num_nonnulls(value_numeric, value_text, value_date, value_boolean) <= 1),
  check (supersedes_id is null or supersedes_id <> id)
);
comment on column claims.period_label is 'Academic year like 2024-25. Leave null for static / point-in-time / event metrics.';
comment on column claims.dimension is 'Optional sub-category, e.g. a branch (CSE), a programme, or a management role. Empty string = overall.';
comment on column claims.supersedes_id is 'A correction points at the accepted claim it replaces. Claims are never edited after submission.';

create index idx_claims_lookup     on claims (institution_id, metric_key, period_label);
create index idx_claims_source     on claims (source_id);
create index idx_claims_supersedes on claims (supersedes_id);
create index idx_claims_workflow   on claims (workflow_status);

create function cip_validate_claim() returns trigger
language plpgsql set search_path = public as $$
declare
  m        metric_definitions%rowtype;
  s        sources%rowtype;
  prior    claims%rowtype;
  n_values int;
begin
  -- Entry path
  if tg_op = 'INSERT' and new.workflow_status not in ('draft', 'submitted') then
    raise exception 'New claims must start as draft or submitted.';
  end if;
  if tg_op = 'UPDATE' and old.workflow_status = 'draft'
     and new.workflow_status in ('accepted', 'rejected') then
    raise exception 'A draft must be submitted before it can be accepted or rejected.';
  end if;

  -- Immutability after submission
  if tg_op = 'UPDATE' and old.workflow_status <> 'draft' then
    if (to_jsonb(new) - 'workflow_status' - 'reviewed_by' - 'reviewed_at' - 'submitted_at' - 'updated_at' - 'period_start_year')
       is distinct from
       (to_jsonb(old) - 'workflow_status' - 'reviewed_by' - 'reviewed_at' - 'submitted_at' - 'updated_at' - 'period_start_year') then
      raise exception 'Claims cannot be edited after submission. Record a correction as a new claim that supersedes this one.';
    end if;
    if old.workflow_status in ('accepted', 'rejected') and new.workflow_status <> old.workflow_status then
      raise exception 'An accepted or rejected claim cannot change status.';
    end if;
  end if;

  -- Timestamps and reviewer
  if new.workflow_status = 'submitted' and (tg_op = 'INSERT' or old.workflow_status is distinct from 'submitted') then
    new.submitted_at := now();
  end if;
  if new.workflow_status in ('accepted', 'rejected')
     and (tg_op = 'INSERT' or old.workflow_status is distinct from new.workflow_status) then
    new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    new.reviewed_at := coalesce(new.reviewed_at, now());
  end if;

  -- Drafts and rejected claims skip the full evidence rules
  if new.workflow_status in ('draft', 'rejected') then
    return new;
  end if;

  -- Correction rules
  if new.supersedes_id is not null then
    select * into prior from claims where id = new.supersedes_id;
    if prior.institution_id <> new.institution_id
       or prior.metric_key <> new.metric_key
       or prior.period_label is distinct from new.period_label
       or prior.dimension <> new.dimension then
      raise exception 'A correction must be for the same institution, metric, period and dimension as the claim it supersedes.';
    end if;
    if prior.workflow_status <> 'accepted' then
      raise exception 'Only an accepted claim can be superseded.';
    end if;
  end if;

  select * into m from metric_definitions where metric_key = new.metric_key;
  if not m.is_active then
    raise exception 'Metric % is not active.', new.metric_key;
  end if;

  -- Period / date requirements
  if m.period_type = 'annual' and new.period_label is null then
    raise exception 'Metric % needs an academic year (period_label).', new.metric_key;
  end if;
  if m.period_type in ('point_in_time', 'event') and new.as_of_date is null then
    raise exception 'Metric % needs an as-of date.', new.metric_key;
  end if;

  -- Value rules
  n_values := num_nonnulls(new.value_numeric, new.value_text, new.value_date, new.value_boolean);
  if n_values = 0 then
    if new.verification_status <> 'unable_to_verify' then
      raise exception 'A claim with no value must have status unable_to_verify.';
    end if;
    if coalesce(btrim(new.notes), '') = '' then
      raise exception 'A claim with no value must say in notes where you looked.';
    end if;
  else
    if (m.value_kind = 'numeric' and new.value_numeric is null)
    or (m.value_kind = 'text'    and new.value_text    is null)
    or (m.value_kind = 'date'    and new.value_date    is null)
    or (m.value_kind = 'boolean' and new.value_boolean is null) then
      raise exception 'Metric % expects a % value.', new.metric_key, m.value_kind;
    end if;
  end if;

  -- Verification status must match the source
  perform cip_check_status_vs_source(new.verification_status, new.source_id, 'A claim');

  -- A verified outcome must actually be verified
  if new.claim_type = 'verified_outcome'
     and new.verification_status not in ('government_verified', 'university_verified', 'regulatory_verified') then
    raise exception 'A verified_outcome claim needs a government, university or regulatory verified status.';
  end if;

  -- Sensitive metrics need full provenance
  if m.is_sensitive and n_values = 1 then
    if new.source_id is null then
      raise exception 'Sensitive claims need a source.';
    end if;
    select * into s from sources where id = new.source_id;
    if coalesce(btrim(new.locator), '') = '' and coalesce(btrim(new.excerpt), '') = '' then
      raise exception 'Sensitive claims need a page/section locator or a short excerpt.';
    end if;
    if new.as_of_date is null and s.document_date is null then
      raise exception 'Sensitive claims need a date (claim as-of date or source document date).';
    end if;
  end if;

  return new;
end $$;

create trigger trg_claims_touch    before update on claims for each row execute function cip_touch_updated_at();
create trigger trg_claims_validate before insert or update on claims for each row execute function cip_validate_claim();

create trigger trg_sources_guard before update on sources
  for each row execute function cip_guard_source_authority();

-- ---------------------------------------------------------------------
-- 10. Risk flags (+ the claims that justify them)
-- ---------------------------------------------------------------------
create table risk_flags (
  id              uuid primary key default gen_random_uuid(),
  institution_id  uuid not null references institutions(id) on delete restrict,
  title           text not null check (btrim(title) <> ''),
  description     text,
  category        text not null check (category in ('recognition', 'regulatory', 'legal', 'financial', 'reputational', 'operational', 'ownership', 'data_integrity')),
  severity        flag_severity not null default 'medium',
  is_gating       boolean not null default false,
  status          flag_status not null default 'open',
  resolution_note text,
  created_by      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_risk_flags_institution on risk_flags (institution_id);

create table risk_flag_claims (
  risk_flag_id uuid not null references risk_flags(id) on delete cascade,
  claim_id     uuid not null references claims(id) on delete restrict,
  primary key (risk_flag_id, claim_id)
);
create index idx_rfc_claim on risk_flag_claims (claim_id);

-- Which claims may justify a GATING flag (rule R1 / D6)
create function cip_claim_is_gating_eligible(p_claim uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from claims c
    where c.id = p_claim
      and c.workflow_status = 'accepted'
      and c.claim_type in ('fact', 'regulatory_action', 'verified_outcome')
      and c.verification_status in ('government_verified', 'university_verified', 'regulatory_verified')
  )
$$;

create function cip_check_flag_gating() returns trigger
language plpgsql set search_path = public as $$
declare
  n_links int;
  n_bad   int;
begin
  if new.is_gating then
    select count(*), count(*) filter (where not cip_claim_is_gating_eligible(claim_id))
      into n_links, n_bad
      from risk_flag_claims where risk_flag_id = new.id;
    if n_links = 0 then
      raise exception 'A gating flag needs linked evidence. Link accepted claims first, then mark the flag as gating.';
    end if;
    if n_bad > 0 then
      raise exception 'A gating flag can only rest on accepted, verified facts, regulatory actions or verified outcomes. Allegations, court matters and unverified claims cannot make a flag gating.';
    end if;
  end if;
  return new;
end $$;
create trigger trg_risk_flags_gating before insert or update on risk_flags
  for each row execute function cip_check_flag_gating();
create trigger trg_risk_flags_touch before update on risk_flags
  for each row execute function cip_touch_updated_at();

create function cip_check_flag_link() returns trigger
language plpgsql set search_path = public as $$
declare
  f risk_flags%rowtype;
  c claims%rowtype;
begin
  if tg_op = 'DELETE' then
    select * into f from risk_flags where id = old.risk_flag_id;
    if found and f.is_gating then
      raise exception 'Unmark the flag as gating before removing its evidence.';
    end if;
    return old;
  end if;
  select * into f from risk_flags where id = new.risk_flag_id;
  select * into c from claims where id = new.claim_id;
  if f.institution_id <> c.institution_id then
    raise exception 'A risk flag can only link to claims about the same institution.';
  end if;
  if f.is_gating and not cip_claim_is_gating_eligible(new.claim_id) then
    raise exception 'This claim cannot support a gating flag (must be accepted, verified, and not an allegation or court matter).';
  end if;
  return new;
end $$;
create trigger trg_rfc_check before insert or update or delete on risk_flag_claims
  for each row execute function cip_check_flag_link();

-- ---------------------------------------------------------------------
-- 11. Analyst observations (opinion, kept apart from evidence)
-- ---------------------------------------------------------------------
create table analyst_observations (
  id               uuid primary key default gen_random_uuid(),
  institution_id   uuid not null references institutions(id) on delete restrict,
  category         text not null default 'other'
                   check (category in ('management_openness', 'competition', 'conversation', 'site_visit', 'conflict_resolution', 'other')),
  body             text not null check (btrim(body) <> ''),
  related_claim_id uuid references claims(id) on delete set null,
  observed_on      date not null default current_date,
  created_by       uuid references auth.users(id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index idx_observations_institution on analyst_observations (institution_id);
create trigger trg_observations_touch before update on analyst_observations
  for each row execute function cip_touch_updated_at();

-- ---------------------------------------------------------------------
-- 12. Assessments (append-only) and brief snapshots (append-only)
-- ---------------------------------------------------------------------
create table assessments (
  id                   uuid primary key default gen_random_uuid(),
  institution_id       uuid not null references institutions(id) on delete restrict,
  version              int not null,
  opportunity_rating   rating_level not null,
  opportunity_rationale text not null check (btrim(opportunity_rationale) <> ''),
  risk_rating          rating_level not null,
  risk_rationale       text not null check (btrim(risk_rationale) <> ''),
  decision             decision_type not null,
  priority             priority_tier not null,
  decision_rationale   text not null check (btrim(decision_rationale) <> ''),
  acknowledged_flag_ids uuid[] not null default '{}',
  created_by           uuid references auth.users(id) on delete set null default auth.uid(),
  created_at           timestamptz not null default now(),
  unique (institution_id, version),
  unique (id, institution_id)
);

create function cip_check_assessment() returns trigger
language plpgsql set search_path = public as $$
declare
  missing uuid[];
begin
  new.version := coalesce((select max(version) from assessments where institution_id = new.institution_id), 0) + 1;
  missing := array(
    select id from risk_flags
     where institution_id = new.institution_id and is_gating and status = 'open'
    except
    select unnest(new.acknowledged_flag_ids)
  );
  if coalesce(array_length(missing, 1), 0) > 0 then
    raise exception 'Acknowledge every open gating flag before recording a decision (% not acknowledged).', array_length(missing, 1);
  end if;
  return new;
end $$;
create trigger trg_assessments_check before insert on assessments
  for each row execute function cip_check_assessment();
create trigger trg_assessments_immutable before update or delete on assessments
  for each row execute function cip_block_mutation();

create table brief_snapshots (
  id             uuid primary key default gen_random_uuid(),
  institution_id uuid not null,
  assessment_id  uuid not null unique,
  snapshot       jsonb not null,
  schema_version int not null default 1,
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  foreign key (assessment_id, institution_id) references assessments (id, institution_id) on delete restrict
);
create trigger trg_snapshots_immutable before update or delete on brief_snapshots
  for each row execute function cip_block_mutation();

-- ---------------------------------------------------------------------
-- 13. Views: current claims, conflicts, display, derived metrics, coverage
--     All use security_invoker so the logged-in user's access rules apply.
-- ---------------------------------------------------------------------

-- A claim is "current" when it is accepted and no accepted claim supersedes it.
create view current_claims with (security_invoker = true) as
select c.*
  from claims c
 where c.workflow_status = 'accepted'
   and not exists (select 1 from claims n
                    where n.supersedes_id = c.id and n.workflow_status = 'accepted');

-- One row per institution + metric + period + dimension (only claims that carry a value).
create view claim_groups with (security_invoker = true) as
select
  c.institution_id, c.metric_key, c.period_label, c.dimension,
  count(*)                                   as n_claims,
  count(distinct c.source_id)                as n_sources,
  min(c.value_numeric)                       as min_numeric,
  max(c.value_numeric)                       as max_numeric,
  array_agg(c.id order by c.created_at, c.id) as claim_ids,
  array_agg(distinct c.verification_status::text) as statuses,
  case
    when count(distinct c.source_id) < 2 then false
    when m.value_kind = 'numeric' then
      (max(c.value_numeric) - min(c.value_numeric)) >
        greatest(coalesce(m.tolerance_abs, 0),
                 coalesce(m.tolerance_pct, 0) / 100.0 * greatest(abs(max(c.value_numeric)), abs(min(c.value_numeric))))
    else count(distinct coalesce(lower(btrim(c.value_text)), c.value_date::text, c.value_boolean::text)) > 1
  end as is_conflicted,
  jsonb_agg(jsonb_build_object(
      'claim_id',         c.id,
      'metric_key',       c.metric_key,
      'period',           c.period_label,
      'dimension',        c.dimension,
      'value',            coalesce(c.value_numeric::text, c.value_text, c.value_date::text, c.value_boolean::text),
      'status',           c.verification_status,
      'claim_type',       c.claim_type,
      'source_id',        c.source_id,
      'source_title',     s.title,
      'source_publisher', s.publisher,
      'source_url',       s.url,
      'source_date',      coalesce(s.document_date, s.retrieved_on)
    ) order by c.created_at, c.id) as inputs
  from current_claims c
  join metric_definitions m on m.metric_key = c.metric_key
  left join sources s on s.id = c.source_id
 where num_nonnulls(c.value_numeric, c.value_text, c.value_date, c.value_boolean) = 1
 group by c.institution_id, c.metric_key, c.period_label, c.dimension,
          m.value_kind, m.tolerance_abs, m.tolerance_pct;

-- What the app shows: each current claim, its source, and a computed display status.
create view claims_display with (security_invoker = true) as
select
  c.*,
  coalesce(g.is_conflicted, false) as is_conflicted,
  case when coalesce(g.is_conflicted, false) then 'conflicting_sources'
       else c.verification_status::text end as display_status,
  s.title        as source_title,
  s.publisher    as source_publisher,
  s.url          as source_url,
  s.authority    as source_authority_type,
  coalesce(s.document_date, s.retrieved_on) as source_date
  from current_claims c
  left join claim_groups g
         on g.institution_id = c.institution_id
        and g.metric_key     = c.metric_key
        and g.period_label is not distinct from c.period_label
        and g.dimension      = c.dimension
  left join sources s on s.id = c.source_id;

-- Weakest-link status for derived values.
create function cip_derived_status(p_statuses text[], p_conflicted boolean) returns text
language sql immutable set search_path = public as $$
  select case
    when p_conflicted then 'conflicting_sources'
    else (select case max(case st when 'unable_to_verify' then 3 when 'institution_reported' then 2 else 1 end)
                   when 3 then 'unable_to_verify'
                   when 2 then 'institution_reported'
                   else 'verified' end
            from unnest(p_statuses) st)
  end
$$;

create view derived_seat_utilization with (security_invoker = true) as
select
  a.institution_id, a.period_label, a.dimension,
  round(100.0 * a.min_numeric / nullif(d.max_numeric, 0), 1) as value_low_pct,
  round(100.0 * a.max_numeric / nullif(d.min_numeric, 0), 1) as value_high_pct,
  (a.is_conflicted or d.is_conflicted)                        as is_conflicted,
  cip_derived_status(a.statuses || d.statuses, a.is_conflicted or d.is_conflicted) as derived_status,
  a.statuses || d.statuses     as input_statuses,
  a.claim_ids || d.claim_ids   as input_claim_ids,
  a.inputs || d.inputs         as inputs,
  'admitted_students / approved_intake' as formula
  from claim_groups a
  join claim_groups d
    on d.institution_id = a.institution_id
   and d.period_label is not distinct from a.period_label
   and d.dimension = a.dimension
   and d.metric_key = 'approved_intake'
 where a.metric_key = 'admitted_students';

create view derived_placement_rate with (security_invoker = true) as
select
  a.institution_id, a.period_label, a.dimension,
  round(100.0 * a.min_numeric / nullif(d.max_numeric, 0), 1) as value_low_pct,
  round(100.0 * a.max_numeric / nullif(d.min_numeric, 0), 1) as value_high_pct,
  (a.is_conflicted or d.is_conflicted)                        as is_conflicted,
  cip_derived_status(a.statuses || d.statuses, a.is_conflicted or d.is_conflicted) as derived_status,
  a.statuses || d.statuses     as input_statuses,
  a.claim_ids || d.claim_ids   as input_claim_ids,
  a.inputs || d.inputs         as inputs,
  'students_placed / students_eligible_placement' as formula
  from claim_groups a
  join claim_groups d
    on d.institution_id = a.institution_id
   and d.period_label is not distinct from a.period_label
   and d.dimension = a.dimension
   and d.metric_key = 'students_eligible_placement'
 where a.metric_key = 'students_placed';

create view derived_admissions_yoy with (security_invoker = true) as
select
  cur.institution_id, cur.period_label, prev.period_label as previous_period_label, cur.dimension,
  (cur.min_numeric - prev.max_numeric) as change_low,
  (cur.max_numeric - prev.min_numeric) as change_high,
  round(100.0 * (cur.min_numeric - prev.max_numeric) / nullif(prev.max_numeric, 0), 1) as change_pct_low,
  round(100.0 * (cur.max_numeric - prev.min_numeric) / nullif(prev.min_numeric, 0), 1) as change_pct_high,
  (cur.is_conflicted or prev.is_conflicted) as is_conflicted,
  cip_derived_status(cur.statuses || prev.statuses, cur.is_conflicted or prev.is_conflicted) as derived_status,
  cur.statuses || prev.statuses   as input_statuses,
  cur.claim_ids || prev.claim_ids as input_claim_ids,
  cur.inputs || prev.inputs       as inputs,
  'admitted_students(this year) - admitted_students(previous year)' as formula
  from claim_groups cur
  join claim_groups prev
    on prev.institution_id = cur.institution_id
   and prev.dimension = cur.dimension
   and prev.metric_key = 'admitted_students'
   and left(prev.period_label, 4)::int = left(cur.period_label, 4)::int - 1
 where cur.metric_key = 'admitted_students'
   and cur.period_label is not null;

-- Admissions series for charts. Missing years are simply absent (never zero).
create view derived_admissions_trend with (security_invoker = true) as
select
  institution_id, dimension,
  count(*)                      as periods_available,
  min(period_label)             as first_period,
  max(period_label)             as last_period,
  (max(left(period_label, 4)::int) - min(left(period_label, 4)::int) + 1) - count(*) as missing_periods,
  bool_or(is_conflicted)        as has_conflict,
  jsonb_agg(jsonb_build_object(
      'period', period_label, 'low', min_numeric, 'high', max_numeric,
      'conflicted', is_conflicted, 'claim_ids', claim_ids) order by period_label) as series
  from claim_groups
 where metric_key = 'admitted_students' and period_label is not null
 group by institution_id, dimension;

-- Per institution x metric: how well established is each evidence category?
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
 where m.is_active;

-- Risk flags with a health check on their evidence.
create view risk_flags_enriched with (security_invoker = true) as
select f.*,
       coalesce(l.n_claims, 0)     as n_linked_claims,
       coalesce(l.n_ineligible, 0) as n_ineligible_claims,
       coalesce(l.n_superseded, 0) as n_superseded_claims
  from risk_flags f
  left join (
    select rc.risk_flag_id,
           count(*) as n_claims,
           count(*) filter (where not cip_claim_is_gating_eligible(rc.claim_id)) as n_ineligible,
           count(*) filter (where exists (select 1 from claims n
                                           where n.supersedes_id = rc.claim_id and n.workflow_status = 'accepted')) as n_superseded
      from risk_flag_claims rc group by rc.risk_flag_id
  ) l on l.risk_flag_id = f.id;

-- ---------------------------------------------------------------------
-- 14. Search (name, short name, alias, city, district, university,
--     any identifier code, owning organisation / promoter)
-- ---------------------------------------------------------------------
create function search_institutions(q text default null) returns setof institutions
language sql stable security invoker set search_path = public as $$
  select distinct i.*
    from institutions i
    left join institutions u on u.id = i.affiliating_university_id
    left join institution_identifiers ii on ii.institution_id = i.id
    left join institution_organisations io on io.institution_id = i.id
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
-- 15. Access control (Row Level Security)
--     Logged-out visitors see nothing. Any logged-in user has access, which
--     is correct while sign-ups are disabled and you are the only user.
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon, public;
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on functions from anon, public;
grant execute on all functions in schema public to authenticated, service_role;

do $$
declare t text;
begin
  foreach t in array array['institutions', 'institution_identifiers', 'organisations', 'institution_organisations',
                           'sources', 'risk_flags', 'risk_flag_claims', 'analyst_observations'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "authenticated read"   on %I for select to authenticated using (true)', t);
    execute format('create policy "authenticated insert" on %I for insert to authenticated with check (true)', t);
    execute format('create policy "authenticated update" on %I for update to authenticated using (true) with check (true)', t);
    execute format('create policy "authenticated delete" on %I for delete to authenticated using (true)', t);
  end loop;
end $$;

-- Reference data: readable, changed only through SQL (not from the app)
alter table metric_definitions enable row level se-- =====================================================================
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
select count(*) as metric_count from metric_definitions;curity;
create policy "authenticated read" on metric_definitions for select to authenticated using (true);

-- Claims: only drafts can be deleted; edits are policed by the claim trigger
alter table claims enable row level security;
create policy "authenticated read"   on claims for select to authenticated using (true);
create policy "authenticated insert" on claims for insert to authenticated with check (true);
create policy "authenticated update" on claims for update to authenticated using (true) with check (true);
create policy "authenticated delete drafts" on claims for delete to authenticated using (workflow_status = 'draft');

-- Append-only tables: read and insert only
alter table assessments enable row level security;
create policy "authenticated read"   on assessments for select to authenticated using (true);
create policy "authenticated insert" on assessments for insert to authenticated with check (true);

alter table brief_snapshots enable row level security;
create policy "authenticated read"   on brief_snapshots for select to authenticated using (true);
create policy "authenticated insert" on brief_snapshots for insert to authenticated with check (true);

commit;
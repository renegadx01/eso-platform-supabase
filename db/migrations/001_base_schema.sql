-- 001_base_schema.sql
-- ĒSO Platform — base schema snapshot, captured from the LIVE Supabase database.
--
-- STATUS: REFLECTS LIVE SCHEMA. The objects below already exist in production;
-- this file exists so the base schema is version-controlled ahead of
-- 002_platform_model_proposed.sql and 003_drop_pace_bands.sql, which build on
-- top of it. Do NOT "apply" this to the current live database — it is a
-- snapshot, not a change. It IS safe to run against a fresh/empty database
-- (everything is guarded with IF NOT EXISTS or duplicate-object handling) to
-- bootstrap a new environment from scratch.
--
-- CAPTURE METHOD & COVERAGE:
--   Columns, types, primary keys, foreign keys, NOT NULL, and defaults were
--   pulled from the PostgREST OpenAPI descriptor (GET /rest/v1/ with
--   Accept: application/openapi+json), read with the service_role key via
--   eow_db.py, on 2026-08-03. This is what's actually live.
--
--   RE-VERIFIED 2026-09-03 by the same method: ZERO DRIFT. All 10 base tables
--   (people, rates, projects, phases, milestones, milestone_slips, actions,
--   flags, allocations, time_entries) and both views match this file exactly —
--   same columns, types, NOT NULL, defaults, PK/FK. No columns added, removed,
--   or retyped since capture. `allocations.pace` remains nullable (see the
--   note above the allocations table). The only object found live but NOT in
--   this file is the rls_auto_enable function — see the coverage gap below.
--
--   NOT captured by this method (PostgREST doesn't expose pg_catalog /
--   information_schema over REST, and there's no direct psql connection
--   configured for this project):
--     * Exact index definitions (beyond the implicit PK index).
--     * CHECK constraints and UNIQUE constraints beyond the primary key.
--     * The exact SQL body of the two views (v_person_week, v_phase_burn) —
--       PostgREST only reports their OUTPUT columns, not their definition.
--       The view bodies below are a best-effort RECONSTRUCTION from column
--       names/semantics and are marked UNVERIFIED. To get the ground truth,
--       run this in the Supabase SQL editor and paste the result back:
--         select viewname, definition from pg_views
--         where viewname in ('v_person_week','v_phase_burn') and schemaname='public';
--     * Exact RLS policy definitions. CLAUDE.md documents the convention as
--       "authenticated role can write; service_role bypasses" — this file
--       reproduces that as a single permissive policy per table (mirroring
--       002_platform_model_proposed.sql's own convention for new tables). If
--       the live policies are actually narrower (e.g. per-command), replace
--       the RLS block below with the output of:
--         select tablename, policyname, cmd, qual, with_check from pg_policies
--         where schemaname = 'public';
--     * Functions. A function public.rls_auto_enable(...) IS live and exposed
--       over PostgREST as /rpc/rls_auto_enable (found 2026-09-03; it was
--       missed by the original 2026-08-03 capture, which only walked table
--       definitions). Its name suggests a helper/event-trigger that enables
--       RLS on newly created tables. PostgREST reports only that it accepts an
--       untyped JSON object and returns 200 — not its argument names, return
--       type, volatility, or body. It is therefore NOT reproduced below, so
--       this file will not recreate it when bootstrapping a fresh database.
--       To capture it, run in the Supabase SQL editor and paste the result in:
--         select p.proname, pg_get_functiondef(p.oid)
--         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--         where n.nspname = 'public';
--       Check for an accompanying event trigger too:
--         select evtname, evtevent, evtfoid::regproc from pg_event_trigger;
--
-- Conventions matched from 002/003:
--   * uuid primary keys default gen_random_uuid() (milestones.id is TEXT).
--   * RLS enabled on every table, permissive policy for "authenticated";
--     service_role bypasses RLS entirely (Postgres built-in behavior).
--   * Everything guarded so the script is safe to re-run.

begin;

-- ============================================================================
-- people
-- ============================================================================
create table if not exists people (
    id              uuid primary key default gen_random_uuid(),
    full_name       text not null,
    key             text not null,
    role            text not null,
    weekly_capacity numeric not null default 40,
    billable        boolean not null default true,
    active          boolean not null default true,
    created_at      timestamptz not null default now()
);

-- ============================================================================
-- rates
-- ============================================================================
create table if not exists rates (
    id              uuid primary key default gen_random_uuid(),
    role            text not null,
    rate_type       text not null,
    hourly_rate     numeric not null,
    effective_date  date not null
);

-- ============================================================================
-- projects
-- ----------------------------------------------------------------------------
-- current_phase_id references phases(id), but phases.project_id references
-- projects(id) — the FK is added after phases exists (see below) to break
-- the circular dependency.
-- ============================================================================
create table if not exists projects (
    id                 uuid primary key default gen_random_uuid(),
    name               text not null,
    client_name        text,
    project_type       text,
    rate_type          text not null default 'standard',
    status             text not null default 'active',
    current_phase_id   uuid,
    total_fee          numeric,
    start_date         date,
    target_end         date,
    created_at         timestamptz not null default now()
);

-- ============================================================================
-- phases
-- ============================================================================
create table if not exists phases (
    id            uuid primary key default gen_random_uuid(),
    project_id    uuid not null references projects(id),
    name          text not null,
    fee           numeric,
    budget_hours  numeric,
    start_date    date,
    end_date      date,
    pct_complete  numeric not null default 0,
    sequence      integer not null default 1
);

do $$
begin
  alter table projects
    add constraint projects_current_phase_id_fkey
    foreign key (current_phase_id) references phases(id);
exception when duplicate_object then
  null;
end $$;

-- ============================================================================
-- milestones (id is TEXT, not uuid — kept as-is per live schema)
-- ============================================================================
create table if not exists milestones (
    id            text primary key,
    project_id    uuid not null references projects(id),
    phase_id      uuid references phases(id),
    label         text not null,
    due_date      date not null,
    status        text not null default 'open',
    is_key        boolean not null default false,
    completed_on  date,
    owner_id      uuid references people(id)
);

-- ============================================================================
-- milestone_slips
-- ============================================================================
create table if not exists milestone_slips (
    id           uuid primary key default gen_random_uuid(),
    milestone_id text not null references milestones(id),
    old_date     date not null,
    new_date     date not null,
    changed_on   date not null default CURRENT_DATE,
    reason       text
);

-- ============================================================================
-- actions
-- ============================================================================
create table if not exists actions (
    id          uuid primary key default gen_random_uuid(),
    project_id  uuid references projects(id),
    raised_by   uuid references people(id),
    kind        text not null,
    body        text not null,
    direction   text,
    needed_by   date,
    priority    text,
    status      text not null default 'open',
    raised_on   date not null default CURRENT_DATE,
    resolved_on date
);

-- ============================================================================
-- flags
-- ============================================================================
create table if not exists flags (
    id          uuid primary key default gen_random_uuid(),
    project_id  uuid references projects(id),
    person_id   uuid references people(id),
    phase_id    uuid references phases(id),
    rule        text not null,
    severity    text not null,
    body        text not null,
    status      text not null default 'open',
    raised_on   timestamptz not null default now(),
    resolved_on timestamptz
);

-- ============================================================================
-- allocations
-- ----------------------------------------------------------------------------
-- NOTE (2026-08-03): the live schema already has `pace` NULLABLE. This means
-- 003_drop_pace_bands.sql's `alter column pace drop not null` is a no-op
-- against current production — either it was already relaxed by hand, or
-- pace was never NOT NULL. Worth confirming with Pete before applying 003;
-- its `comment on column` statement is still useful documentation regardless.
-- ============================================================================
create table if not exists allocations (
    id             uuid primary key default gen_random_uuid(),
    person_id      uuid not null references people(id),
    project_id     uuid not null references projects(id),
    week_of        date not null,
    planned_hours  numeric not null,
    pace           text
);

-- ============================================================================
-- time_entries
-- ============================================================================
create table if not exists time_entries (
    id           uuid primary key default gen_random_uuid(),
    person_id    uuid not null references people(id),
    project_id   uuid not null references projects(id),
    phase_id     uuid references phases(id),
    week_ending  date not null,
    hours        numeric not null,
    source       text not null default 'eow',
    created_at   timestamptz not null default now()
);

-- ============================================================================
-- VIEWS — UNVERIFIED reconstruction. See coverage note at top of file for the
-- exact query to run in the Supabase SQL editor to confirm/correct these.
-- ============================================================================

-- v_person_week(full_name, week_ending, logged_hours, weekly_capacity, utilization_pct)
create or replace view v_person_week as
select
    p.full_name,
    t.week_ending,
    sum(t.hours) as logged_hours,
    p.weekly_capacity,
    round(sum(t.hours) / p.weekly_capacity * 100, 1) as utilization_pct
from time_entries t
join people p on p.id = t.person_id
group by p.full_name, p.weekly_capacity, t.week_ending;

-- v_phase_burn(phase_id, project, phase, budget_hours, fee, accrued_hours, fee_burn, cost_burn)
create or replace view v_phase_burn as
select
    ph.id as phase_id,
    pr.name as project,
    ph.name as phase,
    ph.budget_hours,
    ph.fee,
    coalesce(sum(t.hours), 0) as accrued_hours,
    case when ph.budget_hours > 0
         then ph.fee * coalesce(sum(t.hours), 0) / ph.budget_hours
    end as fee_burn,
    coalesce(sum(t.hours * r.hourly_rate), 0) as cost_burn
from phases ph
join projects pr on pr.id = ph.project_id
left join time_entries t on t.phase_id = ph.id
left join people pe on pe.id = t.person_id
left join rates r on r.role = pe.role and r.rate_type = 'cost'
group by ph.id, pr.name, ph.name, ph.budget_hours, ph.fee;

-- ============================================================================
-- RLS — enable + permissive authenticated policy on every base table.
-- service_role bypasses RLS (Postgres built-in), matching how eow_db.py reads
-- and writes today.
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'people','rates','projects','phases','milestones','milestone_slips',
    'actions','flags','allocations','time_entries'
  ]
  loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for all to authenticated using (true) with check (true)',
      t || '_authenticated_all', t
    );
  end loop;
exception when duplicate_object then
  -- policy already exists on a re-run; ignore.
  null;
end $$;

commit;

-- ============================================================================
-- ROLLBACK NOTES (manual) — only relevant if bootstrapping a fresh database
-- and you need to tear it back down; do NOT run against production, which
-- already has this schema plus live data.
--   drop view if exists v_phase_burn, v_person_week;
--   drop table if exists time_entries, allocations, flags, actions,
--     milestone_slips, milestones;
--   alter table projects drop constraint if exists projects_current_phase_id_fkey;
--   drop table if exists phases, projects, rates, people;
-- ============================================================================

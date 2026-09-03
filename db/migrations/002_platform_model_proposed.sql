-- 002_platform_model_proposed.sql
-- ĒSO Platform — proposed additive migration for the model in PLATFORM_MODEL.md.
--
-- STATUS: PROPOSED. NOT YET APPLIED to the live database.
-- Apply only after Maggie + Pete sign off on the model. Run in the Supabase
-- SQL editor. It is ADDITIVE ONLY: new tables and new NULLABLE columns. It does
-- not alter or drop anything the working EOW write path depends on, so applying
-- it will not break Phase 1.
--
-- Covers Phase 2 (teams, billed-vs-logged), Phase 3 (process framework + RACI),
-- and reserves the Phase 5 scenario dimension. Analytics/views are intentionally
-- left out; this is data shape only.
--
-- Conventions matched from the existing schema:
--   * uuid primary keys default gen_random_uuid() (milestones.id is TEXT, kept as-is).
--   * RLS enabled on new tables with a permissive policy for the authenticated
--     role, mirroring the existing tables. service_role bypasses RLS.
--   * Everything guarded with IF NOT EXISTS so the script is safe to re-run.

begin;

-- ============================================================================
-- PHASE 2a — Teams (org grouping for "by team" visibility)
-- ----------------------------------------------------------------------------
-- Assumption: a person has ONE home team. If people can belong to several teams,
-- replace people.team_id with a team_members(team_id, person_id) join table.
-- ============================================================================
create table if not exists teams (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    lead_id     uuid references people(id),
    active      boolean not null default true,
    created_at  timestamptz not null default now()
);

alter table people add column if not exists team_id uuid references teams(id);

-- ============================================================================
-- PHASE 2b — Billed vs logged on time entries
-- ----------------------------------------------------------------------------
-- Simplest shape first: flags on the existing time_entries row. If billing needs
-- to track invoices/amounts, promote this to a separate billing table later.
-- ============================================================================
alter table time_entries add column if not exists billable    boolean;
alter table time_entries add column if not exists billed       boolean not null default false;
alter table time_entries add column if not exists billed_hours numeric;   -- null = same as hours when billed

-- ============================================================================
-- PHASE 3 — Process Framework + role effort targets + RACI
-- ----------------------------------------------------------------------------
-- A framework is a reusable template. framework_phases are its standard phases.
-- framework_role_effort holds target % effort per role per phase. raci holds the
-- R/A/C/I assignment per role per phase. Live project phases (table: phases) can
-- optionally reference the framework phase they were instantiated from.
-- ============================================================================
create table if not exists process_frameworks (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,          -- e.g. "Residential Custom", "Commercial TI"
    version     text not null default 'v1',
    active      boolean not null default true,
    created_at  timestamptz not null default now()
);

create table if not exists framework_phases (
    id            uuid primary key default gen_random_uuid(),
    framework_id  uuid not null references process_frameworks(id) on delete cascade,
    name          text not null,        -- e.g. "SD", "DD", "CD", "CA"
    sequence      integer not null,
    pct_fee       numeric,              -- share of total fee this phase targets
    unique (framework_id, sequence)
);

create table if not exists framework_role_effort (
    id                  uuid primary key default gen_random_uuid(),
    framework_phase_id  uuid not null references framework_phases(id) on delete cascade,
    role                text not null,  -- matches people.role / rates.role vocabulary
    pct_effort          numeric not null,  -- target share of this phase's hours for this role
    unique (framework_phase_id, role)
);

create table if not exists raci (
    id                  uuid primary key default gen_random_uuid(),
    framework_phase_id  uuid not null references framework_phases(id) on delete cascade,
    role                text not null,
    assignment          text not null check (assignment in ('R','A','C','I')),
    unique (framework_phase_id, role, assignment)
);

-- Link a live project phase back to the framework phase it came from (optional).
alter table phases add column if not exists framework_phase_id uuid references framework_phases(id);
-- Record which framework a project is running (optional).
alter table projects add column if not exists framework_id uuid references process_frameworks(id);

-- ============================================================================
-- PHASE 5 (reserved now) — Pipeline of prospective projects
-- ----------------------------------------------------------------------------
-- Lean mirror that SYNCS FROM THE CRM. Not a CRM rebuild. Just enough to feed
-- capacity forecasting and start/hire timing.
-- ============================================================================
create table if not exists pipeline (
    id                    uuid primary key default gen_random_uuid(),
    name                  text not null,
    client_name           text,
    stage                 text,           -- CRM stage label
    probability           numeric,        -- 0..1
    expected_start        date,
    expected_fee          numeric,
    expected_effort_hours numeric,
    framework_id          uuid references process_frameworks(id),  -- for effort estimate shape
    crm_source            text,           -- which CRM
    crm_ref               text,           -- external id / link for sync
    created_at            timestamptz not null default now()
);

-- ============================================================================
-- PHASE 5 (reserved now) — Plan versions / scenarios
-- ----------------------------------------------------------------------------
-- Reserve the shape only. A plan is the live plan or a named scenario. Allocations
-- can belong to a scenario; NULL plan_id (or the seeded 'Live' plan) is reality.
-- The scenario ENGINE is built in Phase 5; this just prevents a painful retrofit.
-- ============================================================================
create table if not exists plans (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    is_live     boolean not null default false,
    created_at  timestamptz not null default now()
);

insert into plans (name, is_live)
select 'Live', true
where not exists (select 1 from plans where is_live = true);

alter table allocations add column if not exists plan_id uuid references plans(id);
-- Existing allocations with NULL plan_id are treated as the live plan by convention.

-- ============================================================================
-- RLS — enable + permissive authenticated policy on new tables (mirror existing).
-- Adjust to match the exact existing policies if they are stricter.
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'teams','process_frameworks','framework_phases','framework_role_effort',
    'raci','pipeline','plans'
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
-- ROLLBACK NOTES (manual)
-- To undo, drop the new tables and columns in reverse dependency order:
--   alter table allocations drop column if exists plan_id;
--   drop table if exists plans;
--   drop table if exists pipeline;
--   alter table projects drop column if exists framework_id;
--   alter table phases   drop column if exists framework_phase_id;
--   drop table if exists raci, framework_role_effort, framework_phases, process_frameworks;
--   alter table time_entries drop column if exists billed_hours, drop column if exists billed, drop column if exists billable;
--   alter table people drop column if exists team_id;
--   drop table if exists teams;
-- ============================================================================

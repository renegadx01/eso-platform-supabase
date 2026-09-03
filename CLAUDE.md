# CLAUDE.md — eso-platform-supabase

Project brief for Claude Code. Read first.

**See also:** `EOW_System/PLATFORM_STATUS.md` (two levels up) — the living
cross-repo status doc: what's actually live in Supabase right now, real
backfill state, hidden schema constraints found the hard way, and open
decisions pending. Read it alongside this file, not instead of it.

## What this project owns

The **ĒSO Platform operational database** as code: schema, migrations, RLS
policies, and seed data for the Supabase (Postgres) project. This is the live
source of truth (OLTP) where End-of-Week data lands and day-to-day operations
read and write.

This project does **not** own the EOW skill's runtime Python. That lives in the
`eso-eow-reporting` plugin (under `EOW_System/github_upload/eso-claude-plugins/`),
which *consumes* this database via its `eow_db.py` connector. Keep the boundary
clean: schema and DB tooling here; app/skill logic there.

The full product vision and target data model are in `PLATFORM_MODEL.md` in the
plugin repo (`eso-claude-plugins/PLATFORM_MODEL.md`). Read it for the why; this
file is the how for the database.

## Architecture context

- **Supabase = source of truth (OLTP).** All operational writes land here.
- **Snowflake = downstream analytics (OLAP).** A sibling project,
  `eso-platform-snowflake`, ingests from here for macro reporting and
  forecasting. Data flows one direction, Supabase to Snowflake. Nothing writes
  back from Snowflake. Do not duplicate source-of-truth logic there.

## Credentials (shared, outside every repo)

Config lives in `EOW_System/.config/`, two levels up from this project, gitignored
and never committed:
- `supabase.json` — `{ "url": "...", "service_role_key": "..." }`. The
  service_role key bypasses RLS; treat it like a password (never print/log/commit).

Because Claude Code runs locally on Pete's machine, Supabase is reachable
directly (no org network allowlist, unlike the Cowork sandbox). Quick check using
the plugin's connector:

```bash
python3 -c "import sys; sys.path.insert(0,'../../github_upload/eso-claude-plugins/eso-eow-reporting/scripts'); import eow_db; print(eow_db.test_connection('../..'))"
# prints the people row count on success (base = EOW_System, two levels up)
```

## Current schema (live in Supabase)

Master data: `people`, `projects`, `phases` (has `fee`, `budget_hours`,
`pct_complete`), `rates`, `milestones` (id is TEXT). EOW targets: `actions`,
`flags`, `milestone_slips`, `allocations` (person/project/week_of/planned_hours;
`pace` is deprecated, see migration 003), `time_entries`. Views: `v_person_week`,
`v_phase_burn`.

EOW skill contract is now **sidecar v2** (2026-07-27): projects carry hand-entered
`next_week_hours` (mapped to `allocations.planned_hours`); pace/lever/temporary are
gone. `eow_db_write.map_payload` already reflects this and its tests are green.

## Migrations

- `db/migrations/001_base_schema.sql` — **APPLIED** (it's a snapshot of the live
  schema, captured 2026-08-03 via PostgREST introspection: columns, types,
  PK/FK, NOT NULL, defaults). The `v_person_week` / `v_phase_burn` view bodies
  are a best-effort reconstruction and are marked **UNVERIFIED** — PostgREST
  doesn't expose view SQL, only output columns. To confirm/correct them, run
  in the Supabase SQL editor:
  `select viewname, definition from pg_views where viewname in ('v_person_week','v_phase_burn') and schemaname='public';`
  and update the file if the real definitions differ.
- `db/migrations/002_platform_model_proposed.sql` — **PROPOSED, NOT APPLIED.**
  Additive model extension (teams, billed-vs-logged, process framework + RACI,
  pipeline, reserved scenario dimension). Apply only after Maggie + Pete sign off.
  Copied from the plugin repo; this project is now the home for DB migrations, so
  the plugin's `db/` copy can be retired later (ask Pete before deleting it).
- `db/migrations/003_drop_pace_bands.sql` — implements the pace decision below.
  Note: 001's capture shows `allocations.pace` is already nullable live, so
  this may be a no-op — confirm before applying.

## Active decisions

- **Write scope:** persist `actions`, `flags`, `allocations` from the EOW sidecar;
  `time_entries` only when explicit actuals exist (guardrail), else flag-and-skip.
- **Unmatched names:** flag-and-skip, never auto-create. Reconciliation via an
  alias map at `EOW_System/.config/eow_aliases.json`.
- **Pace bands eliminated (2026-07-21, Pete).** The old 1-7 pace-to-hours band
  system (two role tiers) is being removed in favor of **hours entered directly**
  per project. Database impact is small because `allocations.planned_hours`
  already exists: `pace` becomes an optional free-text descriptor, no longer a
  driver. See `003_drop_pace_bands.sql`. The larger change is app-side, in the
  plugin (`eow_hours.py`, the interview, SKILL.md); this project only relaxes the
  column and documents the decision.

## Conventions

- Additive migrations, ordered numerically, each idempotent where possible.
- Never commit secrets. Confirm a safe restore point before applying a migration.
- Match existing RLS conventions (authenticated role can write; service_role
  bypasses). New tables should enable RLS and add matching policies.

# CLAUDE.md — eso-platform-supabase

Project brief for Claude Code. Read first.

**Status note (2026-09-03):** earlier versions of this file pointed to
`EOW_System/PLATFORM_STATUS.md` as a living cross-repo status doc. **That file
does not exist** — it was either never written or removed. Don't go looking for
it. Live-state facts now live in two places instead:
- `db/README.md` — migration status, the drift check, and `001`'s coverage gaps.
- the header comment of `db/migrations/001_base_schema.sql` — capture method,
  re-verification date, and the exact SQL to close each gap.

If a cross-repo status doc gets written later, link it here and delete this note.

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
- `db/migrations/003_drop_pace_bands.sql` — **PROPOSED, NOT APPLIED.**
  Implements the pace decision below. Note: 001's capture shows
  `allocations.pace` is already nullable live, so this may be a no-op —
  confirm before applying.
- `db/migrations/004_dedup_indexes.sql` — **PROPOSED, NOT APPLIED.** Functional
  UNIQUE indexes on `actions` and `flags` (`md5(body)` to stay under btree's
  size limit), backing up the soft-dedup pre-filter in
  `eow_db_write.write_payload()`. Expression indexes, so they can't be
  PostgREST `on_conflict` targets — the write path's soft-dedup + `id`
  fallback remains correct. Additive, low-risk.
- `db/migrations/005_financials_and_health.sql` — **PROPOSED, NOT APPLIED.**
  Adds `financials` (one row per calendar month, QuickBooks P&L +
  balance-sheet import target) and a per-project health table — Maggie's
  "Y/N decisions" node from the Pontis/ĒSO diagram. Unlocks Net Multiplier,
  Overhead Multiplier, Break-Even Rate, Profit-to-Earnings, Cash Flow, Aged AR.
  Additive; no existing table or column is touched.

**Live migration state (verified 2026-09-03):** the database carries the `001`
baseline and nothing else. 002, 003, 004, and 005 are all unapplied. `001`
itself re-verified with zero drift — every column, type, NOT NULL, default,
PK and FK still matches. One object is live but absent from `001`: the
`public.rls_auto_enable` function (`/rpc/rls_auto_enable`); see `001`'s header
for the query to capture it.

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

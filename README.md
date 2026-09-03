# eso-platform-supabase

The ĒSO Platform operational database (Supabase / Postgres) as code: schema,
migrations, RLS, and seed data. Live source of truth for End-of-Week and
day-to-day operations. Consumed by the `eso-eow-reporting` plugin.

See `CLAUDE.md` for the full brief and `eso-claude-plugins/PLATFORM_MODEL.md`
(plugin repo) for the product vision and target data model.

## Setup

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. `cd` here and run `claude`.
3. Confirm connectivity. Runs from any working directory — it resolves every
   path from its own location and tells you exactly what's missing if the
   layout below isn't in place:
   ```bash
   python3 scripts/check_connection.py
   ```
   On success it prints the `people` row count.

## Expected layout — read this before cloning

**This repo is not self-contained, by design.** Neither the database
credentials nor the connector live here: credentials must never be committed,
and the connector belongs to the `eso-eow-reporting` plugin. Both sit in the
shared `EOW_System` folder, so the repo only works when checked out in its
expected position inside it:

```
EOW_System/
  .config/supabase.json                 <- credentials (gitignored, never committed)
  github_upload/eso-claude-plugins/
    eso-eow-reporting/scripts/          <- eow_db.py connector
  platform/
    eso-platform-supabase/              <- THIS REPO
```

Cloned on its own, the SQL and docs are still perfectly readable — the
migrations are plain Postgres and apply through the Supabase SQL editor without
any of this. Only `scripts/check_connection.py` and
`ingestion/monograph_import.py` need the surrounding folder, and both report
clearly rather than failing obscurely when it's absent.

## Migrations

Live in `db/migrations/`, applied in numeric order via the Supabase SQL editor
(or the Supabase CLI).

- `001_base_schema.sql` — **applied** (it's a snapshot of what's already live,
  captured 2026-08-03 via PostgREST introspection, re-verified 2026-09-03 with
  zero drift). The two views are an unverified reconstruction; see the note at
  the top of the file.
- `002_platform_model_proposed.sql` — **proposed, not yet applied.** Additive
  model extension (teams, framework + RACI, pipeline, billed-vs-logged,
  reserved scenario dimension).
- `003_drop_pace_bands.sql` — **proposed, not yet applied.** Relaxes
  `allocations.pace` per the pace-band elimination decision. May already be a
  no-op — 001's capture shows `pace` is nullable live.
- `004_dedup_indexes.sql` — **proposed, not yet applied.** Functional UNIQUE
  indexes on `actions` and `flags`, backing up the write path's soft dedup.
- `005_financials_and_health.sql` — **proposed, not yet applied.** Adds
  `financials` and per-project health tables for the financial KPI layer.

As of 2026-09-03 the live database carries the `001` baseline only — none of
002–005 have been applied. See `db/README.md` for detail and the drift check.

Always confirm a safe restore point before applying anything.

## Secrets

Never commit `supabase.json` or the service_role key. It bypasses RLS.

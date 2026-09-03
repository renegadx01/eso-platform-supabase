# eso-platform-supabase

The ĒSO Platform operational database (Supabase / Postgres) as code: schema,
migrations, RLS, and seed data. Live source of truth for End-of-Week and
day-to-day operations. Consumed by the `eso-eow-reporting` plugin.

See `CLAUDE.md` for the full brief and `eso-claude-plugins/PLATFORM_MODEL.md`
(plugin repo) for the product vision and target data model.

## Setup

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. `cd` here and run `claude`.
3. Credentials live in `EOW_System/.config/supabase.json` (two levels up, outside
   this repo, gitignored). Confirm connectivity:
   ```bash
   python3 -c "import sys; sys.path.insert(0,'../../github_upload/eso-claude-plugins/eso-eow-reporting/scripts'); import eow_db; print(eow_db.test_connection('../..'))"
   ```

## Migrations

Live in `db/migrations/`, applied in numeric order via the Supabase SQL editor
(or the Supabase CLI).

- `001_base_schema.sql` — **applied** (it's a snapshot of what's already live,
  captured 2026-08-03 via PostgREST introspection). The two views are an
  unverified reconstruction; see the note at the top of the file.
- `002_platform_model_proposed.sql` — **proposed, not yet applied.** Additive
  model extension (teams, framework + RACI, pipeline, billed-vs-logged,
  reserved scenario dimension).
- `003_drop_pace_bands.sql` — **proposed, not yet applied.** Relaxes
  `allocations.pace` per the pace-band elimination decision. May already be a
  no-op — 001's capture shows `pace` is nullable live.

Always confirm a safe restore point before applying anything.

## Secrets

Never commit `supabase.json` or the service_role key. It bypasses RLS.

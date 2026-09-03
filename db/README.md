# db/

Database-as-code for the ĒSO Platform (Supabase / Postgres).

## migrations/

Ordered, numerically-prefixed SQL. Apply in order in the Supabase SQL editor or
via the Supabase CLI. Confirm a restore point first.

- `001_base_schema.sql` — APPLIED (reflects live schema, captured 2026-08-03,
  **re-verified 2026-09-03 with zero drift**). Tables, PK/FK/NOT NULL/defaults
  confirmed via PostgREST introspection.
  `v_person_week` / `v_phase_burn` view bodies are a best-effort
  reconstruction — UNVERIFIED, see the note at the top of the file for the
  query to confirm them against the live definitions.
- `002_platform_model_proposed.sql` — PROPOSED. Additive model extension
  (teams, billed-vs-logged, process framework + RACI, pipeline, reserved
  scenario dimension). Gated on Maggie + Pete sign-off.
- `003_drop_pace_bands.sql` — PROPOSED. Relaxes `allocations.pace` (pace bands
  eliminated; hours entered directly). Note: 001's capture shows `pace` is
  already nullable live, so this may be a no-op — confirm before applying.
- `004_dedup_indexes.sql` — PROPOSED. Functional UNIQUE indexes on `actions`
  and `flags` as a backstop to the soft-dedup pre-filter in
  `eow_db_write.write_payload()`. Uses `md5(body)` to stay inside btree's size
  limit. Expression indexes, so they cannot serve as PostgREST `on_conflict`
  targets. Additive and low-risk.
- `005_financials_and_health.sql` — PROPOSED. Adds `financials` (one row per
  calendar month; QuickBooks P&L + balance-sheet import target) and a
  per-project health table, unlocking the financial KPI layer — Net
  Multiplier, Overhead Multiplier, Break-Even Rate, Profit-to-Earnings, Cash
  Flow, Aged AR. Additive; touches no existing table or column.

## Verifying live state

Schema drift check — introspects the live database over PostgREST and compares
against `001`. Prints live relations and their columns; no data is read.

```bash
python3 -c "import sys; sys.path.insert(0,'../../github_upload/eso-claude-plugins/eso-eow-reporting/scripts'); import eow_db; print(eow_db.test_connection('../..'))"
```

Known coverage gaps in `001` (PostgREST cannot expose them): exact index
definitions, CHECK/UNIQUE constraints beyond PKs, the two view bodies, RLS
policy definitions, and functions — including the live
`public.rls_auto_enable` (`/rpc/rls_auto_enable`), which `001` does not
recreate. The queries to capture each are in `001`'s header comment.

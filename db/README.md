# db/

Database-as-code for the ĒSO Platform (Supabase / Postgres).

## migrations/

Ordered, numerically-prefixed SQL. Apply in order in the Supabase SQL editor or
via the Supabase CLI. Confirm a restore point first.

- `001_base_schema.sql` — APPLIED (reflects live schema, captured 2026-08-03).
  Tables, PK/FK/NOT NULL/defaults confirmed via PostgREST introspection.
  `v_person_week` / `v_phase_burn` view bodies are a best-effort
  reconstruction — UNVERIFIED, see the note at the top of the file for the
  query to confirm them against the live definitions.
- `002_platform_model_proposed.sql` — PROPOSED. Additive model extension.
- `003_drop_pace_bands.sql` — PROPOSED. Relaxes `allocations.pace` (pace bands
  eliminated; hours entered directly). Note: 001's capture shows `pace` is
  already nullable live, so this may be a no-op — confirm before applying.

-- 004_dedup_indexes.sql
--
-- Status: PROPOSED, NOT APPLIED.
-- Apply via the Supabase SQL editor after confirming a backup restore point.
--
-- Adds functional UNIQUE indexes to actions and flags as belt-and-suspenders
-- protection against duplicate rows. The primary guard is the soft-dedup
-- pre-filter in eow_db_write.write_payload(); these indexes catch anything
-- that bypasses the write path (manual inserts, future scripts).
--
-- Dedup semantics:
--   actions: same project + person + date + kind + body = duplicate.
--   flags:   same project + person + date + rule + body = duplicate.
--
-- md5(body) is used instead of body directly to keep the index within btree's
-- size limit for long text values. Two different bodies with the same md5 are
-- astronomically unlikely for this use case.
--
-- PostgREST note: these are expression indexes, not column-based constraints,
-- so they cannot be used as PostgREST on_conflict targets. The write path uses
-- soft-dedup + "id" as the on_conflict fallback, which is correct — a new row
-- that passes the pre-filter will always have a new generated UUID id.

CREATE UNIQUE INDEX IF NOT EXISTS actions_dedup_idx
  ON public.actions (project_id, raised_by, raised_on, kind, md5(body));

CREATE UNIQUE INDEX IF NOT EXISTS flags_dedup_idx
  ON public.flags (project_id, person_id, raised_on, rule, md5(body));

-- 003_drop_pace_bands.sql
-- ĒSO Platform — pace-band elimination (decision 2026-07-21, Pete).
--
-- STATUS: PROPOSED. NOT YET APPLIED.
--
-- The old model derived next-week hours from a 1-7 pace label via fixed hour
-- bands split into two role tiers. We are dropping that abstraction: hours are
-- now entered directly per project (allocations.planned_hours, which already
-- exists). This migration only relaxes the DB so `pace` is no longer treated as
-- a required driver. The substantive change is app-side in the eso-eow-reporting
-- plugin (eow_hours.py band tables, the interview, SKILL.md) and is tracked there.
--
-- Additive/relaxing only. Existing pace values are preserved as descriptive text.

begin;

-- Keep the column (historical values stay meaningful) but make explicit it is now
-- an OPTIONAL descriptor, not a driver, and ensure it is nullable so a row can be
-- written with hours and no pace.
alter table allocations alter column pace drop not null;

comment on column allocations.pace is
  'Optional free-text descriptor of intensity. Deprecated as a driver on 2026-07-21; '
  'next-week hours are entered directly in planned_hours, not derived from pace bands.';

commit;

-- ROLLBACK (manual):
--   comment on column allocations.pace is null;
--   -- re-add NOT NULL only if every row has a pace value:
--   -- alter table allocations alter column pace set not null;

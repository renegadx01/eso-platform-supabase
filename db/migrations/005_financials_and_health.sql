-- 005_financials_and_health.sql — PROPOSED, NOT YET APPLIED
--
-- Adds two tables that unlock the financial KPI layer and Maggie's
-- per-project health assessment (the "Y/N decisions" node in the
-- Pontis/ĒSO diagram, 2026-08-11).
--
-- APPLY in the Supabase SQL editor against a known-good restore point.
-- Both tables are additive — no existing tables or columns are touched.
--
-- ── Table 1: financials ──────────────────────────────────────────────────
-- Manual import target for QuickBooks P&L + balance sheet data.
-- Source of truth for the KPIs that need real financial figures:
--   Net Multiplier, Overhead Multiplier, Break-Even Rate,
--   Profit-to-Earnings, Cash Flow, Aged AR.
-- One row per calendar month. Populated by:
--   (a) manual entry via the Financial Import page in the Streamlit app, or
--   (b) future QB CSV import (same page, CSV upload path).
-- All dollar fields nullable — partial months are fine.

CREATE TABLE IF NOT EXISTS public.financials (
  id               uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  period_ending    date NOT NULL UNIQUE,     -- last day of the calendar month
  period_label     text,                     -- display name: "July 2026"

  -- Revenue
  gross_revenue    numeric(12,2),            -- total invoiced / earned before deductions
  net_revenue      numeric(12,2),            -- after reimbursables / consultant pass-throughs

  -- Direct labor (billable staff cost — salaries + burden for the period)
  direct_labor_cost numeric(12,2),

  -- Overhead (rent, non-billable staff, software, G&A, etc.)
  overhead         numeric(12,2),

  -- Derived — can be computed at query time but stored for convenience
  net_profit       numeric(12,2),            -- net_revenue - direct_labor_cost - overhead

  -- Balance sheet snapshots at period end
  accounts_receivable numeric(12,2),         -- total aged AR balance
  cash_balance     numeric(12,2),            -- bank position

  source           text DEFAULT 'manual' CHECK (source IN ('manual', 'quickbooks_csv')),
  notes            text,
  created_by       uuid REFERENCES public.people(id),
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

-- Auto-update updated_at on any write
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TRIGGER financials_updated_at
  BEFORE UPDATE ON public.financials
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.financials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated can read financials"
  ON public.financials FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated can write financials"
  ON public.financials FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ── Table 2: project_health ──────────────────────────────────────────────
-- Maggie's weekly per-project health assessment — the "Y/N decisions" layer
-- from the Pontis diagram. One row per project per week.
-- health values mirror the MKW Rollup PDF convention:
--   on_track | monitor | concern | critical

CREATE TABLE IF NOT EXISTS public.project_health (
  id           uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  project_id   uuid REFERENCES public.projects(id) ON DELETE CASCADE NOT NULL,
  week_ending  date NOT NULL,               -- aligns with EOW week_ending (Friday)
  health       text NOT NULL CHECK (health IN ('on_track', 'monitor', 'concern', 'critical')),
  note         text,                        -- optional narrative from Maggie
  assessed_by  uuid REFERENCES public.people(id),
  created_at   timestamptz DEFAULT now(),
  UNIQUE (project_id, week_ending)          -- one assessment per project per week
);

ALTER TABLE public.project_health ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated can read project_health"
  ON public.project_health FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated can write project_health"
  ON public.project_health FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ── Rollback (if needed) ─────────────────────────────────────────────────
-- DROP TABLE IF EXISTS public.project_health;
-- DROP TABLE IF EXISTS public.financials;
-- DROP FUNCTION IF EXISTS public.set_updated_at();

# monograph_import.py — Monograph time log CSV -> Supabase time_entries.
#
# Monograph has no public API. The only export path is a manual CSV download
# from the Monograph web app: Organization > Time > Export (emailed as a link).
# This script is the mapping layer for that CSV -> time_entries in Supabase.
#
# How to use:
#   1. Export from Monograph: Organization > Time > Time Log (or Organization
#      Timesheet). Download the CSV and drop it in a known location.
#   2. Run: python3 monograph_import.py <path-to-csv> [--dry-run]
#      --dry-run prints what would be written without touching the DB.
#   3. Review the output. Unmatched names are printed and skipped — fix them
#      by adding entries to EOW_System/.config/eow_aliases.json, then re-run.
#
# Column mapping (adjust COLUMN_MAP if Monograph changes its export format):
#   Monograph column name  ->  time_entries field
#   "Date"                 ->  week_ending (rounded to week's Friday — see note)
#   "Team Member"          ->  person_id   (resolved via people table)
#   "Project"              ->  project_id  (resolved via projects table + alias map)
#   "Phase"                ->  phase_id    (resolved via phases table; nullable)
#   "Hours"                ->  hours
#   (no Monograph field)   ->  source = "monograph"
#
# week_ending rounding: time_entries.week_ending is a Friday date (the last day
# of the work week). Monograph logs hours by individual date, so this script
# rounds each date to its containing Friday. This matches the convention used
# by the EOW skill (sidecar's week_ending is always a Friday).
#
# Dedup: time_entries has no unique constraint defined yet. This script checks
# for existing rows matching (person_id, project_id, week_ending) before
# inserting and skips duplicates. If you need to re-import a week, delete the
# existing rows from the Supabase dashboard first.
#
# Open decision (see PLATFORM_STATUS.md): whether this script becomes a
# recurring manual step or is replaced by the platform taking over hour
# tracking directly. For now it is the bridge.

import argparse
import csv
import json
import os
import sys
from datetime import date, timedelta

# ── Path setup ────────────────────────────────────────────────────────────────

# ingestion/ is two levels below EOW_System/:
#   ingestion/ -> eso-platform-supabase/ -> platform/ -> EOW_System/
_HERE = os.path.dirname(os.path.abspath(__file__))
_BASE = os.path.normpath(os.path.join(_HERE, "..", "..", ".."))

# eow_db and eow_reconcile live in the plugin's scripts/ folder
_PLUGIN_SCRIPTS = os.path.normpath(
    os.path.join(_BASE, "github_upload", "eso-claude-plugins",
                 "eso-eow-reporting", "scripts")
)
sys.path.insert(0, _PLUGIN_SCRIPTS)

import eow_db
import eow_reconcile

# ── Column map ────────────────────────────────────────────────────────────────
# Maps Monograph CSV header -> internal key. Adjust if Monograph renames columns.
# Use None for a column that does not exist in the export but has a fixed default.

COLUMN_MAP = {
    "Date":        "date",
    "Team Member": "person_name",
    "Project":     "project_name",
    "Phase":       "phase_name",   # may be blank
    "Hours":       "hours",
    # "Billable":  "billable",     # TODO: wire up once billed-vs-logged decision lands
}

SOURCE = "monograph"

# ── Date helpers ──────────────────────────────────────────────────────────────

def _to_friday(d: date) -> date:
    """Round a date to the Friday of its containing work week (Mon–Fri)."""
    days_until_friday = (4 - d.weekday()) % 7
    return d + timedelta(days=days_until_friday)


def _parse_date(s: str) -> date:
    """Parse a date string. Monograph exports ISO (YYYY-MM-DD) or M/D/YYYY."""
    s = s.strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y"):
        try:
            return date(*[int(x) for x in
                          (__import__("time").strptime(s, fmt))[:3]])
        except ValueError:
            continue
    raise ValueError("Cannot parse date: %r" % s)


# ── Name resolution ───────────────────────────────────────────────────────────

def _build_resolvers(base):
    """Load live people + projects from Supabase and return resolver callables."""
    people = {r["full_name"]: r["id"]
              for r in eow_db.select(base, "people", "select=id,full_name")}
    projects = {r["name"]: r["id"]
                for r in eow_db.select(base, "projects", "select=id,name")}
    phases = {}
    for r in eow_db.select(base, "phases", "select=id,name,project_id"):
        phases.setdefault(r["project_id"], {})[r["name"]] = r["id"]

    aliases = eow_reconcile.load_aliases(base)

    def resolve_person(name):
        canonical = eow_reconcile.resolve_person(name, set(people), aliases.get("people", {}))
        return people.get(canonical) if canonical else None

    def resolve_project(name):
        canonical = eow_reconcile.resolve_project(name, set(projects), aliases.get("projects", {}))
        return projects.get(canonical) if canonical else None

    def resolve_phase(project_id, phase_name):
        if not phase_name or not project_id:
            return None
        return phases.get(project_id, {}).get(phase_name)

    return resolve_person, resolve_project, resolve_phase


# ── Dedup ─────────────────────────────────────────────────────────────────────

def _fetch_existing_time_entries(base, person_ids, week_endings):
    """Return a set of (person_id, project_id, week_ending) already in the DB."""
    existing = set()
    for pid in person_ids:
        rows = eow_db.select(
            base, "time_entries",
            "select=person_id,project_id,week_ending&person_id=eq.%s" % pid,
        )
        for r in rows:
            existing.add((r["person_id"], r["project_id"], r["week_ending"]))
    return existing


# ── CSV parsing ───────────────────────────────────────────────────────────────

def _parse_csv(path):
    """Read the Monograph CSV and return raw rows as dicts using COLUMN_MAP."""
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        actual_headers = set(reader.fieldnames or [])
        missing = set(COLUMN_MAP) - actual_headers
        if missing:
            print("WARNING: Expected columns not found in CSV: %s" % missing)
            print("         Actual headers: %s" % sorted(actual_headers))
            print("         Update COLUMN_MAP at the top of this script if Monograph changed its export format.")
        for row in reader:
            mapped = {}
            for csv_col, internal_key in COLUMN_MAP.items():
                mapped[internal_key] = row.get(csv_col, "").strip()
            rows.append(mapped)
    return rows


# ── Main import logic ─────────────────────────────────────────────────────────

def run_import(csv_path, dry_run=True):
    raw_rows = _parse_csv(csv_path)
    if not raw_rows:
        print("No rows in CSV — nothing to do.")
        return

    resolve_person, resolve_project, resolve_phase = _build_resolvers(_BASE)

    to_insert = []
    skipped = {"unmatched_person": [], "unmatched_project": [], "duplicate": [], "bad_date": [], "zero_hours": []}

    for i, raw in enumerate(raw_rows, start=2):  # row 2 = first data row
        # Parse date
        try:
            row_date = _parse_date(raw["date"])
        except ValueError as e:
            skipped["bad_date"].append({"row": i, "date": raw["date"], "error": str(e)})
            continue

        week_ending = _to_friday(row_date).isoformat()

        # Parse hours
        try:
            hours = float(raw["hours"])
        except (ValueError, KeyError):
            skipped["bad_date"].append({"row": i, "hours": raw.get("hours"), "error": "cannot parse hours"})
            continue
        if hours <= 0:
            skipped["zero_hours"].append({"row": i, "person": raw.get("person_name"), "hours": hours})
            continue

        # Resolve person
        person_id = resolve_person(raw["person_name"])
        if person_id is None:
            skipped["unmatched_person"].append({"row": i, "name": raw["person_name"]})
            continue

        # Resolve project
        project_id = resolve_project(raw["project_name"])
        if project_id is None:
            skipped["unmatched_project"].append({"row": i, "name": raw["project_name"]})
            continue

        # Resolve phase (optional)
        phase_id = resolve_phase(project_id, raw.get("phase_name"))

        to_insert.append({
            "person_id": person_id,
            "project_id": project_id,
            "phase_id": phase_id,
            "week_ending": week_ending,
            "hours": hours,
            "source": SOURCE,
        })

    # Dedup against existing rows
    if to_insert:
        person_ids = {r["person_id"] for r in to_insert}
        week_endings = {r["week_ending"] for r in to_insert}
        existing = _fetch_existing_time_entries(_BASE, person_ids, week_endings)
        unique, dupes = [], []
        for r in to_insert:
            key = (r["person_id"], r["project_id"], r["week_ending"])
            if key in existing:
                dupes.append(r)
            else:
                unique.append(r)
        skipped["duplicate"] = dupes
        to_insert = unique

    # Report
    print("\n── Monograph Import %s ──" % ("(DRY RUN)" if dry_run else "(LIVE)"))
    print("Rows in CSV:         %d" % len(raw_rows))
    print("Ready to insert:     %d" % len(to_insert))
    print("Skipped duplicates:  %d" % len(skipped["duplicate"]))
    print("Skipped (no person): %d" % len(skipped["unmatched_person"]))
    print("Skipped (no project):%d" % len(skipped["unmatched_project"]))
    print("Skipped (bad date):  %d" % len(skipped["bad_date"]))
    print("Skipped (zero hrs):  %d" % len(skipped["zero_hours"]))

    if skipped["unmatched_person"]:
        print("\nUnmatched people (add to eow_aliases.json or fix name in Monograph):")
        for s in skipped["unmatched_person"]:
            print("  row %d: %r" % (s["row"], s["name"]))

    if skipped["unmatched_project"]:
        print("\nUnmatched projects (add to eow_aliases.json or fix name in Monograph):")
        for s in skipped["unmatched_project"]:
            print("  row %d: %r" % (s["row"], s["name"]))

    if not to_insert:
        print("\nNothing to write.")
        return

    if dry_run:
        print("\nDry run — first 3 rows that WOULD be written:")
        for r in to_insert[:3]:
            print(" ", json.dumps(r, default=str))
        return

    written = eow_db.upsert(_BASE, "time_entries", to_insert, "id")
    print("\nWrote %d rows to time_entries." % len(written))


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Import a Monograph Time Log CSV into Supabase time_entries."
    )
    parser.add_argument("csv_path", help="Path to the Monograph exported CSV file.")
    parser.add_argument(
        "--dry-run", action="store_true", default=True,
        help="Print what would be written without touching the DB (default: on).",
    )
    parser.add_argument(
        "--live", action="store_true",
        help="Actually write to the DB. Overrides --dry-run.",
    )
    args = parser.parse_args()
    dry = not args.live

    try:
        run_import(args.csv_path, dry_run=dry)
    except eow_db.SupabaseNotConfigured as e:
        print("ERROR: %s" % e)
        sys.exit(1)

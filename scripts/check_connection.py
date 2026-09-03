#!/usr/bin/env python3
"""Verify this machine can reach the ESO Platform Supabase database.

Run from anywhere:

    python3 scripts/check_connection.py

Every path is resolved from this file's own location, so the working directory
does not matter. On success it prints the people row count. On failure it says
exactly which path it expected and what to do about it, rather than raising a
bare ModuleNotFoundError.

WHY THIS EXISTS: this repo is not self-contained. Both the database credentials
and the connector live OUTSIDE it, in the shared EOW_System folder, on purpose --
the credentials must never be committed, and the connector belongs to the
eso-eow-reporting plugin. So the repo only works when checked out in its
expected position inside that folder. See "Expected layout" in README.md.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))
# repo -> platform/ -> EOW_System/
BASE = os.path.normpath(os.path.join(REPO, "..", ".."))

CONFIG = os.path.join(BASE, ".config", "supabase.json")
CONNECTOR = os.path.join(
    BASE, "github_upload", "eso-claude-plugins", "eso-eow-reporting", "scripts"
)

LAYOUT = """
Expected layout -- this repo must sit inside the shared EOW_System folder:

    EOW_System/
      .config/supabase.json                 <- credentials (never committed)
      github_upload/eso-claude-plugins/
        eso-eow-reporting/scripts/          <- eow_db.py connector
      platform/
        eso-platform-supabase/              <- THIS REPO
"""


def say(msg=""):
    """Print without dying on a non-cp1252 console.

    The shared folder path contains "ESO" spelled with U+0112 (E-macron), which
    a default Windows console cannot encode -- printing it raw raises
    UnicodeEncodeError and takes the whole check down before it reports
    anything useful. Re-encode to whatever the stream actually supports.
    """
    enc = (getattr(sys.stdout, "encoding", None) or "ascii")
    sys.stdout.write(str(msg).encode(enc, "replace").decode(enc, "replace") + "\n")


def fail(what, path, extra=""):
    say(f"FAIL: {what}")
    say(f"  expected at: {path}")
    say(f"  resolved from: {os.path.abspath(__file__)}")
    if extra:
        say(f"  {extra}")
    say(LAYOUT)
    return 1


def main():
    say(f"repo root : {REPO}")
    say(f"EOW_System: {BASE}")
    say()

    if not os.path.isdir(BASE):
        return fail("EOW_System folder not found", BASE,
                    "This repo appears to be cloned standalone.")

    if not os.path.isfile(CONFIG):
        return fail("Supabase credentials not found", CONFIG,
                    'Create it as: {"url": "...", "service_role_key": "..."}')

    if not os.path.isdir(CONNECTOR):
        return fail("eow_db connector not found", CONNECTOR,
                    "Clone the eso-claude-plugins repo into github_upload/.")

    sys.path.insert(0, CONNECTOR)
    try:
        import eow_db
    except ImportError as e:
        return fail(f"could not import eow_db ({e})", CONNECTOR)

    # Sanity-check the config shape before dialling out, so a malformed file
    # reports as a config problem rather than a connection failure.
    try:
        cfg = json.load(open(CONFIG, encoding="utf-8"))
    except (OSError, ValueError) as e:
        return fail(f"credentials file is not valid JSON ({e})", CONFIG)
    missing = [k for k in ("url",) if not cfg.get(k)]
    if missing or not (cfg.get("service_role_key") or cfg.get("key")):
        return fail("credentials file is missing required keys", CONFIG,
                    'Needs "url" and "service_role_key". Never print or commit the key.')

    try:
        count = eow_db.test_connection(BASE)
    except Exception as e:
        say(f"FAIL: connected to the config but the query failed: {e}")
        return 1

    say(f"OK: reached Supabase -- people rows: {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

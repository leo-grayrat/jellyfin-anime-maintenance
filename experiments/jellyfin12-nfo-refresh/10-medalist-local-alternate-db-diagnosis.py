#!/usr/bin/env python3
"""Read-only diagnosis for the Medalist stale Episode version group.

This script never writes to Jellyfin or to jellyfin.db. It inspects the v12
SQLite database to distinguish LocalAlternateVersion / LinkedAlternateVersion,
OwnerId, and PrimaryVersionId relationships after the API unlink pilot.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import urllib.request
import uuid
from pathlib import Path

OWNER_ID = "af564551c864a8892b28736b0de926de"
SERIES_ID = "1e343af25a95b525ae23adc50142693a"
ITEM_IDS = [
    "af564551c864a8892b28736b0de926de",  # S02E02 owner
    "b989bbc54ab7fbd39a4a9962f193a70a",  # S02E03
    "a3073095ba7259a5f91b88cf3ee5835c",  # S02E04
    "5a6d6c57d8c34045ca88256f508d8a4a",  # S02E05
    "a83679a94904aa323c8296277e830ec5",  # S02E06
    "8a8290e4df57d7013c13d21788062dcb",  # S02E07
    "3dfc807ba4ae3faeea6bb3a1349a49c0",  # S02E08
    "59a625fe5a7b8584017e2707eea78cd3",  # S02E09
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--api-key", required=True)
    p.add_argument("--server", default="http://127.0.0.1:8096")
    p.add_argument("--db", help="Optional explicit path to jellyfin.db")
    return p.parse_args()


def normalize_guid(value) -> set[str]:
    """Return possible 32-hex representations for a SQLite GUID value."""
    if value is None:
        return set()
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, bytes):
        if len(value) == 16:
            return {uuid.UUID(bytes=value).hex, uuid.UUID(bytes_le=value).hex}
        try:
            value = value.decode("utf-8")
        except UnicodeDecodeError:
            return {value.hex().lower()}
    text = str(value).strip().strip("{}").replace("-", "").lower()
    return {text} if text else set()


def display_guid(value) -> str:
    if value is None:
        return "<empty>"
    candidates = normalize_guid(value)
    if not candidates:
        return "<empty>"
    # Text GUIDs have exactly one candidate. For binary GUIDs keep both forms visible.
    return " / ".join(sorted(candidates))


def api_system_info(server: str, api_key: str) -> dict:
    server = server.rstrip("/")
    auth = (
        'MediaBrowser Client="db-diagnosis", Device="Python", '
        'DeviceId="db-diagnosis", Version="1.0", Token="%s"' % api_key
    )
    req = urllib.request.Request(server + "/System/Info", headers={"Authorization": auth})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def locate_db(explicit: str | None, info: dict) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))

    program_data = info.get("ProgramDataPath")
    if program_data:
        base = Path(program_data)
        candidates.extend([base / "data" / "jellyfin.db", base / "jellyfin.db"])

    programdata_env = os.environ.get("PROGRAMDATA")
    if programdata_env:
        candidates.append(Path(programdata_env) / "Jellyfin" / "Server" / "data" / "jellyfin.db")

    localappdata = os.environ.get("LOCALAPPDATA")
    if localappdata:
        candidates.append(Path(localappdata) / "jellyfin" / "data" / "jellyfin.db")

    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate).lower()
        if key in seen:
            continue
        seen.add(key)
        if candidate.is_file():
            return candidate.resolve()

    print("Could not auto-locate jellyfin.db.")
    if program_data:
        print(f"Jellyfin ProgramDataPath: {program_data}")
    print("Re-run with: --db <full path to jellyfin.db>")
    raise SystemExit(2)


def open_readonly(db_path: Path) -> sqlite3.Connection:
    uri = db_path.resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=10)
    con.row_factory = sqlite3.Row
    return con


def find_table(con: sqlite3.Connection, wanted: str) -> str:
    rows = con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    for row in rows:
        name = row[0]
        if str(name).lower() == wanted.lower():
            return str(name)
    raise RuntimeError(f"Table {wanted!r} not found. Available tables: {', '.join(str(r[0]) for r in rows)}")


def table_columns(con: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in con.execute(f'PRAGMA table_info("{table}")')}


def pick(row: sqlite3.Row, columns: set[str], name: str):
    return row[name] if name in columns else None


def matches(value, expected_hex: str) -> bool:
    return expected_hex.lower() in normalize_guid(value)


def find_nested_key(obj, key_name: str):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if str(k).lower() == key_name.lower():
                return v
            nested = find_nested_key(v, key_name)
            if nested is not None:
                return nested
    elif isinstance(obj, list):
        for item in obj:
            nested = find_nested_key(item, key_name)
            if nested is not None:
                return nested
    return None


def main() -> int:
    args = parse_args()
    info = api_system_info(args.server, args.api_key)
    db_path = locate_db(args.db, info)

    print("=== Medalist Local Alternate DB Diagnosis ===")
    print("Mode: READ ONLY")
    print(f"Server version: {info.get('Version')}")
    print(f"Database: {db_path}")
    print()

    con = open_readonly(db_path)
    try:
        base_table = find_table(con, "BaseItems")
        linked_table = find_table(con, "LinkedChildren")
        base_cols = table_columns(con, base_table)
        linked_cols = table_columns(con, linked_table)

        required_base = {"Id", "Type", "OwnerId", "PrimaryVersionId", "PresentationUniqueKey"}
        missing_base = sorted(required_base - base_cols)
        if missing_base:
            raise RuntimeError("BaseItems is missing expected columns: " + ", ".join(missing_base))

        required_link = {"ParentId", "ChildId", "ChildType"}
        missing_link = sorted(required_link - linked_cols)
        if missing_link:
            raise RuntimeError("LinkedChildren is missing expected columns: " + ", ".join(missing_link))

        base_rows = con.execute(f'SELECT * FROM "{base_table}"').fetchall()
        by_expected: dict[str, sqlite3.Row] = {}
        for row in base_rows:
            for expected in ITEM_IDS:
                if matches(row["Id"], expected):
                    by_expected[expected] = row

        linked_rows = con.execute(f'SELECT * FROM "{linked_table}"').fetchall()
        owner_links = [r for r in linked_rows if matches(r["ParentId"], OWNER_ID)]

        print("=== BaseItems ===")
        for idx, expected in enumerate(ITEM_IDS, start=2):
            row = by_expected.get(expected)
            key = f"S02E{idx:02d}"
            if row is None:
                print(f"{key} {expected}: NOT FOUND")
                continue

            print(f"{key} {expected}")
            print(f"  Type:                  {pick(row, base_cols, 'Type')}")
            print(f"  OwnerId:               {display_guid(pick(row, base_cols, 'OwnerId'))}")
            print(f"  PrimaryVersionId:      {display_guid(pick(row, base_cols, 'PrimaryVersionId'))}")
            print(f"  PresentationUniqueKey: {pick(row, base_cols, 'PresentationUniqueKey')}")
            print(f"  SeriesId:              {display_guid(pick(row, base_cols, 'SeriesId'))}")
            print(f"  SeasonId:              {display_guid(pick(row, base_cols, 'SeasonId'))}")
            print(f"  ParentIndexNumber:     {pick(row, base_cols, 'ParentIndexNumber')}")
            print(f"  IndexNumber:           {pick(row, base_cols, 'IndexNumber')}")

            data = pick(row, base_cols, "Data")
            if data:
                try:
                    parsed = json.loads(data)
                    lav = find_nested_key(parsed, "LocalAlternateVersions")
                    linked = find_nested_key(parsed, "LinkedAlternateVersions")
                    if lav is not None:
                        print(f"  Data.LocalAlternateVersions: {lav}")
                    if linked is not None:
                        print(f"  Data.LinkedAlternateVersions: {linked}")
                except (TypeError, json.JSONDecodeError):
                    pass
            print()

        print("=== LinkedChildren from Medalist owner ===")
        if not owner_links:
            print("(none)")
        else:
            for row in owner_links:
                child_type = row["ChildType"]
                label = {2: "LocalAlternateVersion", 3: "LinkedAlternateVersion"}.get(child_type, "Other")
                print(
                    f"ChildType={child_type} ({label})  "
                    f"ChildId={display_guid(row['ChildId'])}"
                )

        local_links = [r for r in owner_links if r["ChildType"] == 2]
        linked_links = [r for r in owner_links if r["ChildType"] == 3]
        owned_children = [
            row for expected, row in by_expected.items()
            if expected != OWNER_ID and matches(pick(row, base_cols, "OwnerId"), OWNER_ID)
        ]
        primary_children = [
            row for expected, row in by_expected.items()
            if expected != OWNER_ID and matches(pick(row, base_cols, "PrimaryVersionId"), OWNER_ID)
        ]

        print()
        print("=== Summary ===")
        print(f"Medalist items found:             {len(by_expected)} / 8")
        print(f"Owner LocalAlternateVersion links:{len(local_links)}")
        print(f"Owner LinkedAlternateVersion links:{len(linked_links)}")
        print(f"Children with OwnerId=owner:      {len(owned_children)} / 7")
        print(f"Children with PrimaryVersionId:   {len(primary_children)} / 7")
        print()
        print("READ ONLY: no database or Jellyfin data was changed.")

    finally:
        con.close()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise

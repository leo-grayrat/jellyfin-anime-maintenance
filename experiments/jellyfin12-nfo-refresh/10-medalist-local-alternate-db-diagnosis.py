#!/usr/bin/env python3
"""Read-only diagnosis for the Medalist stale Episode version group.

This script never writes to Jellyfin or to jellyfin.db. It inspects the v12
SQLite database to distinguish LocalAlternateVersion / LinkedAlternateVersion,
OwnerId, and PrimaryVersionId relationships after the API unlink pilot.
"""

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


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--server", default="http://127.0.0.1:8096")
    parser.add_argument("--db", help="Optional explicit path to jellyfin.db")
    return parser.parse_args()


def normalize_guid(value):
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


def display_guid(value):
    if value is None:
        return "<empty>"
    candidates = normalize_guid(value)
    if not candidates:
        return "<empty>"
    return " / ".join(sorted(candidates))


def decode_json(value, source):
    """Decode JSON after explicitly normalizing binary input to text."""
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, bytes):
        value = value.decode("utf-8-sig")
    if not isinstance(value, str):
        raise TypeError(
            "{0}: expected JSON text after normalization, got {1}".format(
                source, type(value).__name__
            )
        )
    try:
        return json.loads(value)
    except Exception as exc:
        raise RuntimeError(
            "{0}: JSON decode failed using {1}: {2}".format(
                source, getattr(json, "__file__", "<unknown>"), exc
            )
        ) from exc


def api_system_info(server, api_key):
    server = server.rstrip("/")
    auth = (
        'MediaBrowser Client="db-diagnosis", Device="Python", '
        'DeviceId="db-diagnosis", Version="1.0", Token="%s"' % api_key
    )
    request = urllib.request.Request(
        server + "/System/Info",
        headers={"Authorization": auth},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = response.read()
    return decode_json(payload, "GET /System/Info")


def locate_db(explicit, info):
    candidates = []
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

    seen = set()
    for candidate in candidates:
        key = str(candidate).lower()
        if key in seen:
            continue
        seen.add(key)
        if candidate.is_file():
            return candidate.resolve()

    print("Could not auto-locate jellyfin.db.")
    if program_data:
        print("Jellyfin ProgramDataPath: {0}".format(program_data))
    print("Re-run with: --db <full path to jellyfin.db>")
    raise SystemExit(2)


def open_readonly(db_path):
    uri = db_path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def find_table(connection, wanted):
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
    for row in rows:
        name = row[0]
        if str(name).lower() == wanted.lower():
            return str(name)
    raise RuntimeError(
        "Table {0!r} not found. Available tables: {1}".format(
            wanted, ", ".join(str(row[0]) for row in rows)
        )
    )


def table_columns(connection, table):
    return {
        str(row[1])
        for row in connection.execute('PRAGMA table_info("{0}")'.format(table))
    }


def pick(row, columns, name):
    return row[name] if name in columns else None


def matches(value, expected_hex):
    return expected_hex.lower() in normalize_guid(value)


def find_nested_key(obj, key_name):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if str(key).lower() == key_name.lower():
                return value
            nested = find_nested_key(value, key_name)
            if nested is not None:
                return nested
    elif isinstance(obj, list):
        for item in obj:
            nested = find_nested_key(item, key_name)
            if nested is not None:
                return nested
    return None


def main():
    args = parse_args()

    print("=== Medalist Local Alternate DB Diagnosis ===")
    print("Mode: READ ONLY")
    print("Python: {0}".format(sys.version.replace("\n", " ")))
    print("Python executable: {0}".format(sys.executable))
    print("json module: {0}".format(getattr(json, "__file__", "<unknown>")))
    print()

    print("[Stage 1/4] Reading Jellyfin /System/Info ...")
    info = api_system_info(args.server, args.api_key)
    print("[Stage 1/4] OK - server version: {0}".format(info.get("Version")))

    print("[Stage 2/4] Locating jellyfin.db ...")
    db_path = locate_db(args.db, info)
    print("[Stage 2/4] OK - database: {0}".format(db_path))

    print("[Stage 3/4] Opening SQLite database read-only ...")
    connection = open_readonly(db_path)
    print("[Stage 3/4] OK")

    try:
        print("[Stage 4/4] Reading BaseItems and LinkedChildren ...")
        base_table = find_table(connection, "BaseItems")
        linked_table = find_table(connection, "LinkedChildren")
        base_cols = table_columns(connection, base_table)
        linked_cols = table_columns(connection, linked_table)

        required_base = {"Id", "Type", "OwnerId", "PrimaryVersionId", "PresentationUniqueKey"}
        missing_base = sorted(required_base - base_cols)
        if missing_base:
            raise RuntimeError(
                "BaseItems is missing expected columns: " + ", ".join(missing_base)
            )

        required_link = {"ParentId", "ChildId", "ChildType"}
        missing_link = sorted(required_link - linked_cols)
        if missing_link:
            raise RuntimeError(
                "LinkedChildren is missing expected columns: " + ", ".join(missing_link)
            )

        base_rows = connection.execute(
            'SELECT * FROM "{0}"'.format(base_table)
        ).fetchall()
        by_expected = {}
        for row in base_rows:
            for expected in ITEM_IDS:
                if matches(row["Id"], expected):
                    by_expected[expected] = row

        linked_rows = connection.execute(
            'SELECT * FROM "{0}"'.format(linked_table)
        ).fetchall()
        owner_links = [
            row for row in linked_rows if matches(row["ParentId"], OWNER_ID)
        ]
        print("[Stage 4/4] OK")
        print()

        print("=== BaseItems ===")
        for idx, expected in enumerate(ITEM_IDS, start=2):
            row = by_expected.get(expected)
            key = "S02E{0:02d}".format(idx)
            if row is None:
                print("{0} {1}: NOT FOUND".format(key, expected))
                continue

            print("{0} {1}".format(key, expected))
            print("  Type:                  {0}".format(pick(row, base_cols, "Type")))
            print("  OwnerId:               {0}".format(display_guid(pick(row, base_cols, "OwnerId"))))
            print("  PrimaryVersionId:      {0}".format(display_guid(pick(row, base_cols, "PrimaryVersionId"))))
            print("  PresentationUniqueKey: {0}".format(pick(row, base_cols, "PresentationUniqueKey")))
            print("  SeriesId:              {0}".format(display_guid(pick(row, base_cols, "SeriesId"))))
            print("  SeasonId:              {0}".format(display_guid(pick(row, base_cols, "SeasonId"))))
            print("  ParentIndexNumber:     {0}".format(pick(row, base_cols, "ParentIndexNumber")))
            print("  IndexNumber:           {0}".format(pick(row, base_cols, "IndexNumber")))

            data = pick(row, base_cols, "Data")
            if data:
                try:
                    parsed = decode_json(data, "BaseItems.Data for {0}".format(key))
                    local_alt = find_nested_key(parsed, "LocalAlternateVersions")
                    linked_alt = find_nested_key(parsed, "LinkedAlternateVersions")
                    if local_alt is not None:
                        print("  Data.LocalAlternateVersions: {0}".format(local_alt))
                    if linked_alt is not None:
                        print("  Data.LinkedAlternateVersions: {0}".format(linked_alt))
                except Exception as exc:
                    print("  Data JSON note: {0}".format(exc))
            print()

        print("=== LinkedChildren from Medalist owner ===")
        if not owner_links:
            print("(none)")
        else:
            for row in owner_links:
                child_type = row["ChildType"]
                label = {
                    2: "LocalAlternateVersion",
                    3: "LinkedAlternateVersion",
                }.get(child_type, "Other")
                print(
                    "ChildType={0} ({1})  ChildId={2}".format(
                        child_type, label, display_guid(row["ChildId"])
                    )
                )

        local_links = [row for row in owner_links if row["ChildType"] == 2]
        linked_links = [row for row in owner_links if row["ChildType"] == 3]
        owned_children = [
            row
            for expected, row in by_expected.items()
            if expected != OWNER_ID
            and matches(pick(row, base_cols, "OwnerId"), OWNER_ID)
        ]
        primary_children = [
            row
            for expected, row in by_expected.items()
            if expected != OWNER_ID
            and matches(pick(row, base_cols, "PrimaryVersionId"), OWNER_ID)
        ]

        print()
        print("=== Summary ===")
        print("Medalist items found:               {0} / 8".format(len(by_expected)))
        print("Owner LocalAlternateVersion links:  {0}".format(len(local_links)))
        print("Owner LinkedAlternateVersion links: {0}".format(len(linked_links)))
        print("Children with OwnerId=owner:        {0} / 7".format(len(owned_children)))
        print("Children with PrimaryVersionId:     {0} / 7".format(len(primary_children)))
        print()
        print("READ ONLY: no database or Jellyfin data was changed.")

    finally:
        connection.close()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("ERROR: {0}".format(exc), file=sys.stderr)
        raise

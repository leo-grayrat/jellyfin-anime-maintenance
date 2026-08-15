#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ntpath
import os
from collections import Counter
from typing import Iterable, Sequence

REQUIRED_FIELDS = {"SourcePath", "TargetRelativePath", "Status", "SourceVolume"}
ACTIVE_STATUS = "CONFIRMED"
IGNORE_STATUS = "IGNORE"


def _windowsish(path: str) -> bool:
    drive, _ = ntpath.splitdrive(path)
    return bool(drive) or "\\" in path


def _path_key(path: str) -> str:
    value = str(path).strip()
    if _windowsish(value):
        return ntpath.normpath(value.replace("/", "\\")).casefold()
    return os.path.normpath(value).casefold()


def _volume(path: str) -> str:
    drive, _ = ntpath.splitdrive(str(path).strip().replace("/", "\\"))
    return drive.casefold()


def _validate_relative_path(path: str) -> str:
    value = str(path or "").strip().replace("/", "\\")
    drive, tail = ntpath.splitdrive(value)
    parts = [part for part in tail.split("\\") if part not in ("", ".")]
    if not value or drive or ntpath.isabs(value) or any(part == ".." for part in parts):
        raise ValueError(f"TargetRelativePath must be a safe relative path: {path}")
    return ntpath.normpath(value)


def load_manifest(path: str) -> tuple[list[dict], list[dict]]:
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = set(reader.fieldnames or [])
        missing = sorted(REQUIRED_FIELDS - fields)
        if missing:
            raise ValueError(f"manifest missing required column(s): {', '.join(missing)}")
        rows = list(reader)

    active: list[dict] = []
    ignored: list[dict] = []
    seen_sources: set[str] = set()

    for index, raw in enumerate(rows, start=2):
        row = dict(raw)
        source = (row.get("SourcePath") or "").strip()
        status = (row.get("Status") or "").strip().upper()
        if not source:
            raise ValueError(f"row {index} is missing SourcePath")

        key = _path_key(source)
        if key in seen_sources:
            raise ValueError(f"duplicate SourcePath: {source}")
        seen_sources.add(key)

        if status == IGNORE_STATUS:
            ignored.append(row)
            continue
        if status != ACTIVE_STATUS:
            raise ValueError(f"row {index} has unsupported Status={status!r}; expected CONFIRMED or IGNORE")

        row["TargetRelativePath"] = _validate_relative_path(row.get("TargetRelativePath", ""))
        active.append(row)

    return active, ignored


def _join_target(root: str, relative: str) -> str:
    if _windowsish(root):
        return ntpath.normpath(ntpath.join(root, relative))
    parts = relative.replace("\\", "/").split("/")
    return os.path.normpath(os.path.join(root, *parts))


def build_plan(rows: Sequence[dict], c_root: str, d_root: str | None) -> list[dict]:
    roots = {"c:": c_root}
    if d_root:
        roots["d:"] = d_root

    plan: list[dict] = []
    seen_targets: dict[str, str] = {}
    for row in rows:
        source = (row.get("SourcePath") or "").strip()
        declared = (row.get("SourceVolume") or "").strip().casefold()
        actual = _volume(source)
        volume = declared or actual
        if declared and actual and declared != actual:
            raise ValueError(f"SourceVolume disagrees with SourcePath: {source} ({declared} != {actual})")
        if volume == "d:" and not d_root:
            raise ValueError("active D: rows exist but no D: target root was supplied")
        root = roots.get(volume)
        if root is None:
            raise ValueError(f"no target root configured for source volume {volume or '<none>'}: {source}")
        root_volume = _volume(root)
        if volume and root_volume and volume != root_volume:
            raise ValueError(f"hardlink target root crosses volumes: {source} -> {root}")

        relative = _validate_relative_path(row.get("TargetRelativePath", ""))
        target = _join_target(root, relative)
        key = _path_key(target)
        previous = seen_targets.get(key)
        if previous is not None:
            raise ValueError(f"duplicate target path: {target} :: {previous} / {source}")
        seen_targets[key] = source
        plan.append(
            {
                "source_path": source,
                "target_path": target,
                "source_volume": volume,
                "target_relative_path": relative,
                "work_title": row.get("WorkTitle", ""),
                "media_class": row.get("MediaClass", ""),
                "state": "UNCLASSIFIED",
                "reason": "",
            }
        )
    return plan


def preflight(plan: Sequence[dict]) -> list[dict]:
    classified: list[dict] = []
    errors: list[str] = []

    for source_row in plan:
        row = dict(source_row)
        source = row["source_path"]
        target = row["target_path"]
        if not os.path.isfile(source):
            row["state"] = "ERROR"
            row["reason"] = "source file is missing"
            errors.append(f"missing source: {source}")
        elif os.path.exists(target):
            try:
                if os.path.isfile(target) and os.path.samefile(source, target):
                    row["state"] = "REUSABLE"
                    row["reason"] = "target is already the same hardlinked file"
                else:
                    row["state"] = "CONFLICT"
                    row["reason"] = "target already exists and is not this source"
                    errors.append(f"conflict: {target}")
            except OSError as exc:
                row["state"] = "CONFLICT"
                row["reason"] = f"cannot verify existing target: {exc}"
                errors.append(f"conflict: {target}: {exc}")
        else:
            row["state"] = "MISSING"
            row["reason"] = "target does not exist"
        classified.append(row)

    if errors:
        raise ValueError(f"preflight failed with {len(errors)} error(s): {' | '.join(errors[:10])}")
    return classified


def apply_plan(plan: Sequence[dict]) -> dict:
    states = Counter(row.get("state", "") for row in plan)
    unexpected = sorted(state for state in states if state not in {"MISSING", "REUSABLE"})
    if unexpected:
        raise ValueError(f"plan contains non-applicable states: {', '.join(unexpected)}")

    created: list[tuple[str, str]] = []
    try:
        for row in plan:
            if row["state"] == "REUSABLE":
                continue
            source = row["source_path"]
            target = row["target_path"]
            parent = os.path.dirname(target)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.link(source, target)
            if not os.path.samefile(source, target):
                raise RuntimeError(f"created target is not the same file as source: {target}")
            created.append((source, target))
    except Exception:
        for source, target in reversed(created):
            try:
                if os.path.isfile(target) and os.path.samefile(source, target):
                    os.unlink(target)
            except OSError:
                pass
        raise

    return {
        "created": len(created),
        "reused": states.get("REUSABLE", 0),
        "total": len(plan),
    }


def write_plan_csv(path: str, rows: Iterable[dict]) -> None:
    fieldnames = [
        "source_path",
        "target_path",
        "source_volume",
        "target_relative_path",
        "work_title",
        "media_class",
        "state",
        "reason",
    ]
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply the reviewed anime decision manifest mechanically. No filename or episode parsing is performed."
    )
    parser.add_argument("manifest", help="Reviewed manifest CSV")
    parser.add_argument("--c-root", default=r"C:\resource\video\anime", help="C: target root")
    parser.add_argument("--d-root", help="D: target root; required when active D: rows are present")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Create hardlinks. Without this flag the script is dry-run only.",
    )
    parser.add_argument("--log", help="Optional CSV path for the classified plan")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    active, ignored = load_manifest(args.manifest)
    plan = build_plan(active, args.c_root, args.d_root)
    classified = preflight(plan)
    counts = Counter(row["state"] for row in classified)

    if args.log:
        write_plan_csv(args.log, classified)

    print(f"Manifest rows: {len(active) + len(ignored)}")
    print(f"Active rows:   {len(active)}")
    print(f"Ignored rows:  {len(ignored)}")
    print(f"Missing:       {counts.get('MISSING', 0)}")
    print(f"Reusable:      {counts.get('REUSABLE', 0)}")

    if not args.apply:
        print("Mode: DRY-RUN (no filesystem changes)")
        return 0

    result = apply_plan(classified)
    print("Mode: APPLY")
    print(f"Created:       {result['created']}")
    print(f"Reused:        {result['reused']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

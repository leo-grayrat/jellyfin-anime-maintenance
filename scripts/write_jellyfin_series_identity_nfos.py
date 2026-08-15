#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from typing import Sequence
from xml.sax.saxutils import escape

DEFAULT_VIEW_ROOT = r"D:\Resource\BangumiLink\View-v3"

SERIES_IDENTITIES = (
    {
        "group": "2017年动画",
        "directory_prefix": "[JYFanSub][Youjo_Senki][01-12+SP]",
        "title": "幼女战记",
        "tvdb": "315500",
        "tmdb": "69346",
        "imdb": "tt6455986",
    },
    {
        "group": "2023年动画",
        "directory_prefix": "[Nekomoe kissaten&VCB-Studio] THE IDOLM@STER CINDERELLA GIRLS U149",
        "title": "偶像大师 灰姑娘女孩 U149",
        "tvdb": "424278",
        "tmdb": "216391",
        "imdb": "tt26699386",
    },
    {
        "group": "2025年4月新番",
        "directory_prefix": "[Prejudice-Studio] 前桥魔女 Maebashi Witches",
        "title": "前桥魔女",
        "tvdb": "454132",
        "tmdb": "270602",
        "imdb": "tt35351289",
    },
    {
        "group": "2025年7月新番",
        "directory_prefix": "[DBD-Raws][克雷瓦提斯-魔兽之王与婴儿与尸之勇者-]",
        "title": "克雷瓦提斯-魔兽之王与婴儿与尸之勇者-",
        "tvdb": "451793",
        "tmdb": "258348",
        "imdb": "tt32991344",
    },
    {
        "group": "2025年7月新番",
        "directory_prefix": "[Nekomoe kissaten&LoliHouse] Ruri no Houseki",
        "title": "瑠璃的宝石",
        "tvdb": "454330",
        "tmdb": "271649",
        "imdb": "tt37113118",
    },
    {
        "group": "2025年10月新番",
        "directory_prefix": "[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26",
        "title": "藤本树 17-26",
        "tvdb": "467641",
        "tmdb": "299778",
        "imdb": "tt38491451",
    },
    {
        "group": "2025年10月新番",
        "directory_prefix": "SPY×FAMILY Season 3",
        "title": "SPY×FAMILY",
        "tvdb": "405920",
        "tmdb": "120089",
        "imdb": "tt13706018",
    },
)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Write minimal tvshow.nfo identity files for the seven Series that did not "
            "auto-identify reliably in the grouped View-v3 libraries. Default is dry-run."
        )
    )
    parser.add_argument("--view-root", default=DEFAULT_VIEW_ROOT)
    parser.add_argument("--apply", action="store_true", help="Actually create missing tvshow.nfo files")
    return parser.parse_args(argv)


def render_nfo(entry: dict) -> str:
    title = escape(str(entry["title"]))
    tvdb = escape(str(entry["tvdb"]))
    tmdb = escape(str(entry["tmdb"]))
    imdb = escape(str(entry["imdb"]))
    return (
        "<tvshow>\n"
        f"  <title>{title}</title>\n"
        f"  <uniqueid type=\"tvdb\">{tvdb}</uniqueid>\n"
        f"  <uniqueid type=\"tmdb\">{tmdb}</uniqueid>\n"
        f"  <uniqueid type=\"imdb\">{imdb}</uniqueid>\n"
        "</tvshow>\n"
    )


def _logical_path(path: str) -> str:
    return os.path.abspath(os.path.expanduser(str(path)))


def _filesystem_path(path: str) -> str:
    value = _logical_path(path)
    if os.name != "nt" or value.startswith("\\\\?\\"):
        return value
    if value.startswith("\\\\"):
        return "\\\\?\\UNC\\" + value[2:]
    return "\\\\?\\" + value


def _path_under_or_equal(path: str, root: str) -> bool:
    path_abs = os.path.normcase(_logical_path(path))
    root_abs = os.path.normcase(_logical_path(root))
    try:
        return os.path.commonpath([path_abs, root_abs]) == root_abs
    except ValueError:
        return False


def _read_text(path: str) -> str:
    with open(_filesystem_path(path), "r", encoding="utf-8", newline=None) as handle:
        return handle.read()


def _find_series_directory(view_root: str, entry: dict) -> str:
    root = _logical_path(view_root)
    group = _logical_path(os.path.join(root, str(entry["group"])))
    if not _path_under_or_equal(group, root):
        raise ValueError(f"group path escapes view root: {group}")
    if os.path.islink(_filesystem_path(group)):
        raise ValueError(f"group path must not be a symlink: {group}")
    if not os.path.isdir(_filesystem_path(group)):
        raise ValueError(f"group directory not found: {group}")

    prefix = str(entry["directory_prefix"]).casefold()
    matches: list[str] = []
    with os.scandir(_filesystem_path(group)) as scan:
        for child in scan:
            if child.is_symlink() or not child.is_dir(follow_symlinks=False):
                continue
            if child.name.casefold().startswith(prefix):
                logical_child = _logical_path(os.path.join(group, child.name))
                if not _path_under_or_equal(logical_child, root):
                    raise ValueError(f"series path escapes view root: {logical_child}")
                matches.append(logical_child)

    matches.sort(key=str.casefold)
    if len(matches) != 1:
        names = ", ".join(os.path.basename(path) for path in matches) or "<none>"
        raise ValueError(
            f"expected exactly one directory for {entry['title']} under {group} "
            f"with prefix {entry['directory_prefix']!r}; found {len(matches)}: {names}"
        )
    return matches[0]


def build_plan(view_root: str, entries: Sequence[dict] = SERIES_IDENTITIES) -> list[dict]:
    root = _logical_path(view_root)
    if not os.path.isdir(_filesystem_path(root)):
        raise ValueError(f"view root not found: {root}")

    plan: list[dict] = []
    seen_series: set[str] = set()
    for entry in entries:
        series_dir = _find_series_directory(root, entry)
        series_key = os.path.normcase(series_dir)
        if series_key in seen_series:
            raise ValueError(f"multiple identity entries resolve to the same series directory: {series_dir}")
        seen_series.add(series_key)

        nfo_path = _logical_path(os.path.join(series_dir, "tvshow.nfo"))
        if not _path_under_or_equal(nfo_path, root):
            raise ValueError(f"nfo path escapes view root: {nfo_path}")

        expected_content = render_nfo(entry)
        fs_nfo = _filesystem_path(nfo_path)
        if not os.path.lexists(fs_nfo):
            state = "CREATE"
        elif not os.path.isfile(fs_nfo):
            state = "CONFLICT"
        else:
            state = "REUSE" if _read_text(nfo_path) == expected_content else "CONFLICT"

        plan.append(
            {
                "group": str(entry["group"]),
                "directory_prefix": str(entry["directory_prefix"]),
                "title": str(entry["title"]),
                "tvdb": str(entry["tvdb"]),
                "tmdb": str(entry["tmdb"]),
                "imdb": str(entry["imdb"]),
                "series_dir": series_dir,
                "nfo_path": nfo_path,
                "expected_content": expected_content,
                "state": state,
            }
        )

    return plan


def _assert_plan_writable(plan: Sequence[dict]) -> None:
    conflicts = [row for row in plan if row.get("state") == "CONFLICT"]
    unknown = [row for row in plan if row.get("state") not in {"CREATE", "REUSE", "CONFLICT"}]
    if unknown:
        raise RuntimeError(f"unexpected plan state: {unknown[0].get('state')}")
    if conflicts:
        paths = ", ".join(str(row.get("nfo_path")) for row in conflicts)
        raise RuntimeError(f"CONFLICT: refusing to write any file while conflicting tvshow.nfo exists: {paths}")


def _atomic_write_new(path: str, content: str) -> None:
    fs_path = _filesystem_path(path)
    directory = os.path.dirname(_logical_path(path))
    fs_directory = _filesystem_path(directory)
    if os.path.lexists(fs_path):
        raise FileExistsError(f"destination appeared after preflight; refusing to overwrite: {path}")

    fd, temp_path = tempfile.mkstemp(prefix=".tvshow.nfo.", suffix=".tmp", dir=fs_directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if os.path.lexists(fs_path):
            raise FileExistsError(f"destination appeared during write; refusing to overwrite: {path}")
        os.replace(temp_path, fs_path)
        temp_path = ""
    finally:
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)


def apply_plan(plan: Sequence[dict]) -> int:
    _assert_plan_writable(plan)
    created = 0
    for row in plan:
        if row["state"] == "REUSE":
            continue
        if row["state"] != "CREATE":
            raise RuntimeError(f"unexpected plan state: {row['state']}")
        _atomic_write_new(str(row["nfo_path"]), str(row["expected_content"]))
        created += 1

    for row in plan:
        actual = _read_text(str(row["nfo_path"]))
        if actual != row["expected_content"]:
            raise RuntimeError(f"verification failed after write: {row['nfo_path']}")
    return created


def print_plan(plan: Sequence[dict], view_root: str) -> None:
    creates = sum(row["state"] == "CREATE" for row in plan)
    reuses = sum(row["state"] == "REUSE" for row in plan)
    conflicts = sum(row["state"] == "CONFLICT" for row in plan)
    print("\n=== Seven Series Identity NFO Plan ===")
    print(f"View root: {_logical_path(view_root)}")
    print(f"Targets: {len(plan)}")
    print(f"Create: {creates}")
    print(f"Reuse: {reuses}")
    print(f"Conflicts: {conflicts}\n")
    for row in plan:
        print(
            f"[{row['state']:<8}] {row['title']} :: "
            f"TVDB={row['tvdb']} TMDB={row['tmdb']} IMDb={row['imdb']}"
        )
        print(f"           {row['series_dir']}")
    print("\nOnly tvshow.nfo files are planned. No Jellyfin scan is triggered.")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    plan = build_plan(args.view_root)
    print_plan(plan, args.view_root)

    if not args.apply:
        if any(row["state"] == "CONFLICT" for row in plan):
            print("\nDRY RUN found conflicts. Nothing was written.", file=sys.stderr)
            return 2
        print("\nDRY RUN finished. Nothing was written.")
        return 0

    # Rebuild the plan immediately before any filesystem mutation.
    plan = build_plan(args.view_root)
    _assert_plan_writable(plan)
    created = apply_plan(plan)

    # Re-read the whole target set after mutation. This must now be all REUSE.
    verified = build_plan(args.view_root)
    non_reuse = [row for row in verified if row["state"] != "REUSE"]
    if non_reuse:
        raise RuntimeError(
            "post-write verification did not converge to REUSE: "
            + ", ".join(f"{row['title']}={row['state']}" for row in non_reuse)
        )

    print(f"\nCreated {created} tvshow.nfo file(s). Verified {len(verified)} target(s) as REUSE.")
    print("No Jellyfin scan was triggered.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)

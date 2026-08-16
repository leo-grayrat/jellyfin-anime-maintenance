#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ntpath
import os
import re
import tempfile
from dataclasses import dataclass, field
from typing import Sequence

VIDEO_EXTS = {'.mkv', '.mp4', '.avi', '.m2ts', '.ts'}
ACTIVE_STATUS = 'CONFIRMED'


def _windowsish(path: str) -> bool:
    drive, _ = ntpath.splitdrive(str(path))
    return bool(drive) or '\\' in str(path)


def _pathmod(path: str):
    return ntpath if _windowsish(path) else os.path


def _norm(path: str) -> str:
    pm = _pathmod(path)
    return pm.normpath(str(path)).casefold()


def _basename(path: str) -> str:
    return _pathmod(path).basename(path)


def _dirname(path: str) -> str:
    return _pathmod(path).dirname(path)


def _join(root: str, relative: str) -> str:
    pm = _pathmod(root)
    if pm is ntpath:
        return ntpath.normpath(ntpath.join(root, relative.replace('/', '\\')))
    parts = relative.replace('\\', '/').split('/')
    return os.path.normpath(os.path.join(root, *parts))


def _relpath(path: str, root: str) -> str:
    pm = ntpath if _windowsish(path) or _windowsish(root) else os.path
    return pm.relpath(path, root)


def _is_under(path: str, root: str) -> bool:
    pm = ntpath if _windowsish(path) or _windowsish(root) else os.path
    try:
        return pm.commonpath([pm.normpath(path), pm.normpath(root)]).casefold() == pm.normpath(root).casefold()
    except ValueError:
        return False


def _source_volume(path: str) -> str:
    drive, _ = ntpath.splitdrive(path)
    return drive.upper()


def _to_int(value) -> int | None:
    text = str(value or '').strip()
    if not text:
        return None
    try:
        return int(float(text))
    except ValueError:
        return None


def _work_root_for_path(path: str, source_roots: Sequence[str]) -> tuple[str, str] | None:
    matches = [root for root in source_roots if _is_under(path, root)]
    if not matches:
        return None
    root = max(matches, key=len)
    rel = _relpath(path, root)
    pm = ntpath if _windowsish(path) or _windowsish(root) else os.path
    parts = [p for p in re.split(r'[\\/]+', rel) if p not in ('', '.')]
    if not parts:
        return None

    # Known source layouts:
    #   <year>/<YYYY-MM>/<work>/...
    #   <year>/<work>/...
    #   <work>/...
    count = 1
    if re.fullmatch(r'\d{4}', parts[0]):
        count = 2
        if len(parts) >= 2 and re.fullmatch(r'\d{4}-\d{2}', parts[1]):
            count = 3
    if len(parts) < count + 1 and os.path.splitext(parts[-1])[1].lower() in VIDEO_EXTS:
        return None

    work_root = root
    for part in parts[:count]:
        work_root = pm.join(work_root, part)
    return pm.normpath(work_root), root


@dataclass
class OffsetModel:
    season: int
    offset: int
    raws: list[int] = field(default_factory=list)

    @property
    def min_raw(self) -> int:
        return min(self.raws)

    @property
    def max_raw(self) -> int:
        return max(self.raws)


@dataclass
class Profile:
    work_root: str
    source_root: str
    work_title: str
    library_group: str
    target_season_dirs: dict[int, str]
    models: list[OffsetModel]
    seasons: set[int]
    non_episode_dirs: set[str]


def build_profiles(rows: Sequence[dict], source_roots: Sequence[str]) -> dict[str, Profile]:
    grouped: dict[str, list[dict]] = {}
    roots: dict[str, str] = {}
    for row in rows:
        if str(row.get('Status') or '').upper() != ACTIVE_STATUS:
            continue
        source = str(row.get('SourcePath') or '').strip()
        found = _work_root_for_path(source, source_roots)
        if not found:
            continue
        work_root, source_root = found
        key = _norm(work_root)
        grouped.setdefault(key, []).append(row)
        roots[key] = source_root

    profiles: dict[str, Profile] = {}
    for key, items in grouped.items():
        titles = {str(r.get('WorkTitle') or '').strip() for r in items if str(r.get('WorkTitle') or '').strip()}
        groups = {str(r.get('LibraryGroup') or '').strip() for r in items if str(r.get('LibraryGroup') or '').strip()}
        if len(titles) != 1 or len(groups) != 1:
            continue

        work_root = _work_root_for_path(str(items[0]['SourcePath']), source_roots)[0]
        season_dirs: dict[int, str] = {}
        model_raws: dict[tuple[int, int], list[int]] = {}
        seasons: set[int] = set()
        non_episode_dirs: set[str] = set()

        for row in items:
            source = str(row.get('SourcePath') or '')
            media = str(row.get('MediaClass') or '')
            if media != 'TV_EPISODE':
                parent = _dirname(source)
                if _norm(parent) != _norm(work_root):
                    non_episode_dirs.add(_norm(parent))
                continue

            season = _to_int(row.get('Season'))
            ep = _to_int(row.get('EpisodeStart'))
            raw = _to_int(row.get('RawEpisodeLabel'))
            if season is None or ep is None:
                continue
            seasons.add(season)

            target = str(row.get('TargetRelativePath') or '').strip()
            if target:
                season_dirs.setdefault(season, _dirname(target))
            if raw is not None:
                model_raws.setdefault((season, raw - ep), []).append(raw)

        models = [OffsetModel(season=s, offset=o, raws=vals) for (s, o), vals in model_raws.items() if vals]
        profiles[key] = Profile(
            work_root=work_root,
            source_root=roots[key],
            work_title=next(iter(titles)),
            library_group=next(iter(groups)),
            target_season_dirs=season_dirs,
            models=models,
            seasons=seasons,
            non_episode_dirs=non_episode_dirs,
        )
    return profiles


def _find_profile(path: str, profiles: dict[str, Profile]) -> Profile | None:
    matches = [p for p in profiles.values() if _is_under(path, p.work_root)]
    if not matches:
        return None
    return max(matches, key=lambda p: len(p.work_root))


def _inside_non_episode_zone(path: str, profile: Profile) -> bool:
    parent = _dirname(path)
    return any(_is_under(parent, d) for d in profile.non_episode_dirs)


def _extract_explicit_sxxeyy(name: str) -> tuple[int, int] | None:
    match = re.search(r'(?i)(?<![A-Z0-9])S(\d{1,2})E(\d{1,3})(?!\d)', name)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def _raw_candidates(name: str) -> list[int]:
    values: list[int] = []
    patterns = [
        r'\[(\d{1,3})(?:v\d+)?\]',
        r'\s-\s*(\d{1,3})(?:v\d+)?(?=\s|\[|\.|$)',
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, name, re.I):
            value = int(match.group(1))
            if 0 <= value <= 200 and value not in values:
                values.append(value)
    return values


def _choose_from_models(candidates: Sequence[int], profile: Profile) -> tuple[int, int, int] | None:
    scored: list[tuple[int, int, int, int]] = []
    for raw in candidates:
        for model in profile.models:
            ep = raw - model.offset
            if ep <= 0 or ep > 200:
                continue
            if raw < model.min_raw - 1 or raw > model.max_raw + 5:
                continue
            score = 1
            if raw == model.max_raw + 1:
                score = 4
            elif raw > model.max_raw:
                score = 3
            elif raw in model.raws:
                score = 2
            scored.append((score, raw, model.season, ep))

    if not scored:
        return None
    best_score = max(item[0] for item in scored)
    best = {(raw, season, ep) for score, raw, season, ep in scored if score == best_score}
    logical = {(season, ep) for raw, season, ep in best}
    if len(logical) != 1:
        return None
    raw, season, ep = sorted(best)[0]
    return raw, season, ep


def classify_new_path(path: str, profiles: dict[str, Profile], existing_rows: Sequence[dict]) -> dict | None:
    if os.path.splitext(_basename(path))[1].lower() not in VIDEO_EXTS:
        return None

    profile = _find_profile(path, profiles)
    if not profile or _inside_non_episode_zone(path, profile):
        return None

    name = _basename(path)
    explicit = _extract_explicit_sxxeyy(name)
    if explicit:
        season, episode = explicit
        if profile.seasons and season not in profile.seasons:
            return None
        raw_label = str(episode)
        basis = '增量维护：已知作品目录 + 文件名显式 SxxEyy'
    else:
        chosen = _choose_from_models(_raw_candidates(name), profile)
        if not chosen:
            return None
        raw, season, episode = chosen
        raw_label = str(raw)
        basis = '增量维护：已知作品目录 + 既有 manifest 集数偏移模型'

    season_dir = profile.target_season_dirs.get(season)
    if not season_dir:
        return None

    key = f'S{season:02d}E{episode:02d}'
    target_rel = _join(season_dir, f'{key} - {name}')
    version_group = f'{profile.work_title}|{key}'
    same_episode = [
        row for row in existing_rows
        if str(row.get('VersionGroup') or '') == version_group
        and str(row.get('Status') or '').upper() == ACTIVE_STATUS
    ]
    if not same_episode:
        version_role = 'PRIMARY'
    elif re.search(r'(?i)v2', name):
        version_role = 'CORRECTED_V2'
    else:
        version_role = 'ALTERNATE_VERSION'

    return {
        'SourcePath': path,
        'WorkTitle': profile.work_title,
        'LibraryGroup': profile.library_group,
        'CatalogBucket': 'TV_MAIN',
        'MediaClass': 'TV_EPISODE',
        'Season': str(season),
        'EpisodeStart': str(episode),
        'EpisodeEnd': str(episode),
        'RawEpisodeLabel': raw_label,
        'SpecialType': '',
        'VersionGroup': version_group,
        'VersionRole': version_role,
        'TargetRelativePath': target_rel,
        'DecisionBasis': basis,
        'Status': 'CONFIRMED',
        'Confidence': 'HIGH',
        'SourceVolume': _source_volume(path),
        'EvidenceURL': '',
        'Notes': '自动增量；如字幕组/目录结构变化，仍以已知作品根目录和高置信集数解析为准。',
    }


def load_manifest(path: str) -> tuple[list[str], list[dict]]:
    with open(path, 'r', encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        fields = list(reader.fieldnames or [])
        rows = list(reader)

    needed = {
        'SourcePath', 'WorkTitle', 'LibraryGroup', 'MediaClass', 'Season',
        'EpisodeStart', 'RawEpisodeLabel', 'TargetRelativePath', 'Status'
    }
    missing = sorted(needed - set(fields))
    if missing:
        raise ValueError('manifest missing required column(s): ' + ', '.join(missing))
    return fields, rows


def discover_new_paths(source_roots: Sequence[str], existing_rows: Sequence[dict]) -> list[str]:
    existing = {_norm(str(row.get('SourcePath') or '')) for row in existing_rows}
    found: list[str] = []
    for root in source_roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _, filenames in os.walk(root):
            for filename in filenames:
                if os.path.splitext(filename)[1].lower() not in VIDEO_EXTS:
                    continue
                path = os.path.join(dirpath, filename)
                if _norm(path) not in existing:
                    found.append(path)
    return sorted(found, key=_norm)


def plan_new_rows(source_roots: Sequence[str], existing_rows: Sequence[dict]) -> tuple[list[dict], list[str]]:
    profiles = build_profiles(existing_rows, source_roots)
    planned: list[dict] = []
    review: list[str] = []
    seen_targets: set[str] = set()

    for path in discover_new_paths(source_roots, existing_rows):
        row = classify_new_path(path, profiles, list(existing_rows) + planned)
        if row is None:
            review.append(path)
            continue
        target_key = _norm(row['TargetRelativePath'])
        if target_key in seen_targets:
            review.append(path)
            continue
        seen_targets.add(target_key)
        planned.append(row)
    return planned, review


def _target_root_for_source(source: str, target_roots: dict[str, str]) -> str:
    volume = _source_volume(source)
    key = volume.casefold()
    if key in target_roots:
        return target_roots[key]
    if '' in target_roots:
        return target_roots['']
    raise ValueError(f'no target root configured for source volume {volume or "<none>"}: {source}')


def _atomic_write_manifest(path: str, fieldnames: Sequence[str], rows: Sequence[dict]) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or '.'
    fd, temp_path = tempfile.mkstemp(prefix='.manifest-', suffix='.csv', dir=directory)
    os.close(fd)
    try:
        with open(temp_path, 'w', encoding='utf-8-sig', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction='ignore')
            writer.writeheader()
            writer.writerows(rows)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def apply_updates(
    manifest_path: str,
    fieldnames: Sequence[str],
    existing_rows: Sequence[dict],
    planned_rows: Sequence[dict],
    target_roots: dict[str, str],
) -> dict:
    created: list[tuple[str, str]] = []
    targets: list[tuple[dict, str]] = []

    # Preflight every new target before writing anything.
    for row in planned_rows:
        source = row['SourcePath']
        if not os.path.isfile(source):
            raise ValueError(f'missing source: {source}')
        root = _target_root_for_source(source, target_roots)
        target = _join(root, row['TargetRelativePath'])
        if os.path.exists(target):
            if os.path.isfile(target) and os.path.samefile(source, target):
                targets.append((row, target))
                continue
            raise ValueError(f'target conflict: {target}')
        targets.append((row, target))

    try:
        for row, target in targets:
            source = row['SourcePath']
            if os.path.exists(target):
                continue
            parent = _dirname(target)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.link(source, target)
            if not os.path.samefile(source, target):
                raise RuntimeError(f'created target is not the same hardlinked file: {target}')
            created.append((source, target))

        rows_to_write = [dict(row) for row in existing_rows] + [dict(row) for row in planned_rows]
        if 'index' in fieldnames:
            existing_indexes = [_to_int(row.get('index')) for row in existing_rows]
            next_index = max((value for value in existing_indexes if value is not None), default=-1) + 1
            for row in rows_to_write[len(existing_rows):]:
                row['index'] = str(next_index)
                next_index += 1
        _atomic_write_manifest(manifest_path, fieldnames, rows_to_write)
    except Exception:
        for source, target in reversed(created):
            try:
                if os.path.isfile(target) and os.path.samefile(source, target):
                    os.unlink(target)
            except OSError:
                pass
        raise

    return {'created': len(created), 'appended': len(planned_rows)}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Discover newly downloaded anime episodes from an existing reviewed manifest and extend the hardlink view.'
    )
    parser.add_argument('manifest', help='Private reviewed manifest CSV')
    parser.add_argument(
        '--source-root', action='append', dest='source_roots',
        help='Source root to scan; repeatable. Defaults to D:\\Bangumi and C:\\bangumi.'
    )
    parser.add_argument('--c-root', default=r'C:\resource\video\anime', help='C: hardlink view root')
    parser.add_argument('--d-root', default=r'D:\Resource\BangumiLink\View', help='D: hardlink view root')
    parser.add_argument(
        '--apply', action='store_true',
        help='Create new hardlinks and append rows to the manifest. Default is dry-run.'
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    source_roots = args.source_roots or [r'D:\Bangumi', r'C:\bangumi']
    fields, rows = load_manifest(args.manifest)
    planned, review = plan_new_rows(source_roots, rows)

    print(f'Existing manifest rows: {len(rows)}')
    print(f'New video files:        {len(planned) + len(review)}')
    print(f'Auto-classified:        {len(planned)}')
    print(f'Needs review:           {len(review)}')
    for row in planned:
        print(f"[PLAN] {row['SourcePath']} -> {row['TargetRelativePath']}")
    for path in review:
        print(f'[REVIEW] {path}')

    if not args.apply:
        print('Mode: DRY-RUN (no filesystem or manifest changes)')
        return 0
    if review:
        raise SystemExit('Refusing --apply while unclassified new video files exist. Review them first.')

    roots = {'c:': args.c_root, 'd:': args.d_root}
    result = apply_updates(args.manifest, fields, rows, planned, roots)
    print('Mode: APPLY')
    print(f"Created hardlinks: {result['created']}")
    print(f"Manifest rows added: {result['appended']}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

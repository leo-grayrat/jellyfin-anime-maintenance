import csv
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'update_anime_incremental_view.py'
spec = importlib.util.spec_from_file_location('incremental', SCRIPT)
incremental = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = incremental
spec.loader.exec_module(incremental)

FIELDS = [
    'SourcePath','WorkTitle','LibraryGroup','CatalogBucket','MediaClass','Season',
    'EpisodeStart','EpisodeEnd','RawEpisodeLabel','SpecialType','VersionGroup',
    'VersionRole','TargetRelativePath','DecisionBasis','Status','Confidence',
    'SourceVolume','EvidenceURL','Notes'
]


def base_row(source, work, group, season, episode, raw, target):
    return {
        'SourcePath': source,
        'WorkTitle': work,
        'LibraryGroup': group,
        'CatalogBucket': 'TV_MAIN',
        'MediaClass': 'TV_EPISODE',
        'Season': str(season),
        'EpisodeStart': str(episode),
        'EpisodeEnd': str(episode),
        'RawEpisodeLabel': str(raw),
        'SpecialType': '',
        'VersionGroup': f'{work}|S{season:02d}E{episode:02d}',
        'VersionRole': 'PRIMARY',
        'TargetRelativePath': target,
        'DecisionBasis': 'seed',
        'Status': 'CONFIRMED',
        'Confidence': 'HIGH',
        'SourceVolume': 'D:',
        'EvidenceURL': '',
        'Notes': '',
    }


class IncrementalViewTests(unittest.TestCase):
    def test_hyakkano_absolute_number_is_inferred_from_manifest_offset(self):
        root = r'D:\Bangumi'
        work_root = root + r'\2026\2026-07\君のことが大大大大大好きな100人の彼女 第3期'
        rows = []
        for raw in range(25, 31):
            ep = raw - 24
            source = work_root + rf'\[LoliHouse] Hyakkano - {raw:02d} [WebRip].mkv'
            target = rf'2026年07月新番\君のことが大大大大大好きな100人の彼女\Season 03\S03E{ep:02d} - [LoliHouse] Hyakkano - {raw:02d} [WebRip].mkv'
            rows.append(base_row(source, '君のことが大大大大大好きな100人の彼女', '2026年07月新番', 3, ep, raw, target))
        profiles = incremental.build_profiles(rows, [root])
        new_path = work_root + r'\[LoliHouse] Hyakkano - 31 [WebRip 1080p].mkv'
        result = incremental.classify_new_path(new_path, profiles, rows)
        self.assertEqual(result['Season'], '3')
        self.assertEqual(result['EpisodeStart'], '7')
        self.assertEqual(result['RawEpisodeLabel'], '31')
        self.assertTrue(result['TargetRelativePath'].startswith(
            r'2026年07月新番\君のことが大大大大大好きな100人の彼女\Season 03\S03E07 - '
        ))

    def test_world_dancing_changed_group_nested_folder_explicit_sxxeyy(self):
        root = r'D:\Bangumi'
        work_root = root + r'\2026\2026-07\ワールド イズ ダンシング'
        rows = []
        for ep in (1, 2, 3):
            source = work_root + rf'\[Studio GreenTea] The World Is Dancing [{ep:02d}][WebRip].mp4'
            target = rf'2026年07月新番\ワールド イズ ダンシング\Season 01\S01E{ep:02d} - [Studio GreenTea] The World Is Dancing [{ep:02d}][WebRip].mp4'
            rows.append(base_row(source, 'ワールド イズ ダンシング', '2026年07月新番', 1, ep, ep, target))
        profiles = incremental.build_profiles(rows, [root])
        new_path = work_root + r'\[Nix-Raws] World Is Dancing S01 [CATCHPLAY WEB-DL 1080p AVC AAC][SC_TC]\[Nix-Raws] World Is Dancing S01E05 [CATCHPLAY WEB-DL 1080p AVC AAC][SC_TC].mkv'
        result = incremental.classify_new_path(new_path, profiles, rows)
        self.assertEqual(result['Season'], '1')
        self.assertEqual(result['EpisodeStart'], '5')
        self.assertEqual(result['WorkTitle'], 'ワールド イズ ダンシング')
        self.assertIn(r'S01E05 - [Nix-Raws] World Is Dancing S01E05', result['TargetRelativePath'])

    def test_new_file_inside_known_non_episode_subdir_is_not_auto_classified(self):
        root = r'D:\Bangumi'
        work_root = root + r'\2025\2025-07\Clevatess'
        episode = base_row(
            work_root + r'\[DBD-Raws][Clevatess][01].mkv',
            'Clevatess', '2025年07月新番', 1, 1, 1,
            r'2025年07月新番\Clevatess\Season 01\S01E01 - [DBD-Raws][Clevatess][01].mkv'
        )
        extra = episode.copy()
        extra.update({
            'SourcePath': work_root + r'\特典映像\[Tokuten] 01.mkv',
            'CatalogBucket': 'TV_EXTRA',
            'MediaClass': 'EXTRA_OTHER',
            'Season': '',
            'EpisodeStart': '',
            'EpisodeEnd': '',
            'RawEpisodeLabel': '',
            'VersionGroup': '',
            'TargetRelativePath': r'2025年07月新番\Clevatess\extras\[Tokuten] 01.mkv',
        })
        profiles = incremental.build_profiles([episode, extra], [root])
        new_path = work_root + r'\特典映像\[Tokuten] 02.mkv'
        self.assertIsNone(incremental.classify_new_path(new_path, profiles, [episode, extra]))

    def test_apply_creates_only_new_hardlink_and_appends_manifest_atomically(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            source_root = td / 'source'
            work_root = source_root / '2026' / '2026-07' / 'Show'
            work_root.mkdir(parents=True)
            old = work_root / 'Show - 01.mkv'
            new = work_root / 'Show - 02.mkv'
            old.write_bytes(b'one')
            new.write_bytes(b'two')
            target_root = td / 'view'
            old_target_rel = os.path.join(
                '2026年07月新番', 'Show', 'Season 01', 'S01E01 - Show - 01.mkv'
            )
            rows = [base_row(str(old), 'Show', '2026年07月新番', 1, 1, 1, old_target_rel)]
            manifest = td / 'manifest.csv'
            with manifest.open('w', encoding='utf-8-sig', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)

            profiles = incremental.build_profiles(rows, [str(source_root)])
            planned = incremental.classify_new_path(str(new), profiles, rows)
            result = incremental.apply_updates(
                str(manifest), FIELDS, rows, [planned], {'': str(target_root)}
            )
            self.assertEqual(result['created'], 1)
            target = target_root / Path(planned['TargetRelativePath'])
            self.assertTrue(target.exists())
            self.assertTrue(os.path.samefile(new, target))
            with manifest.open('r', encoding='utf-8-sig', newline='') as f:
                updated = list(csv.DictReader(f))
            self.assertEqual(len(updated), 2)
            self.assertEqual(updated[-1]['SourcePath'], str(new))


if __name__ == '__main__':
    unittest.main()

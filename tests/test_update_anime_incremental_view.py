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
    def test_pre_2024_series_cannot_recreate_quarter_library(self):
        for year in (2022, 2023):
            with self.subTest(year=year), tempfile.TemporaryDirectory() as td:
                root = Path(td) / 'source'
                work = root / str(year) / 'Old Show'
                work.mkdir(parents=True)
                old = work / 'Old Show - 01.mkv'
                new = work / 'Old Show - 02.mkv'
                old.write_bytes(b'one')
                new.write_bytes(b'two')
                bad_group = f'{year}年07月新番'
                old_target = os.path.join(bad_group, 'Old Show', 'Season 01', 'S01E01 - Old Show - 01.mkv')
                rows = [base_row(str(old), 'Old Show', bad_group, 1, 1, 1, old_target)]

                with self.assertRaisesRegex(ValueError, f'{year}年动画'):
                    incremental.plan_new_rows([], rows, tracked_source_roots=[str(root)])

    def test_pre_2024_annual_series_stays_annual_on_new_episode(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'source'
            work = root / '2022' / 'Old Show'
            work.mkdir(parents=True)
            old = work / 'Old Show - 01.mkv'
            new = work / 'Old Show - 02.mkv'
            old.write_bytes(b'one')
            new.write_bytes(b'two')
            rows = [base_row(
                str(old), 'Old Show', '2022年动画', 1, 1, 1,
                os.path.join('2022年动画', 'Old Show', 'Season 01', 'S01E01 - Old Show - 01.mkv'),
            )]

            planned, review = incremental.plan_new_rows([], rows, tracked_source_roots=[str(root)])

            self.assertEqual(review, [])
            self.assertEqual(len(planned), 1)
            self.assertEqual(planned[0]['LibraryGroup'], '2022年动画')
            self.assertEqual(
                planned[0]['TargetRelativePath'],
                os.path.join('2022年动画', 'Old Show', 'Season 01', 'S01E02 - Old Show - 02.mkv'),
            )

    def test_2024_quarter_series_remains_allowed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'source'
            work = root / '2024' / '2024-10' / 'New Show'
            work.mkdir(parents=True)
            old = work / 'New Show - 01.mkv'
            new = work / 'New Show - 02.mkv'
            old.write_bytes(b'one')
            new.write_bytes(b'two')
            rows = [base_row(
                str(old), 'New Show', '2024年10月新番', 1, 1, 1,
                os.path.join('2024年10月新番', 'New Show', 'Season 01', 'S01E01 - New Show - 01.mkv'),
            )]

            planned, review = incremental.plan_new_rows([], rows, tracked_source_roots=[str(root)])

            self.assertEqual(review, [])
            self.assertEqual(len(planned), 1)
            self.assertEqual(planned[0]['LibraryGroup'], '2024年10月新番')

    def test_tracked_source_scans_known_work_and_keeps_its_new_quarter(self):
        with tempfile.TemporaryDirectory() as td:
            source_root = Path(td) / 'source'
            work = source_root / '2026' / '2026-10' / 'Sequel S2'
            unfinished = source_root / '2022' / 'Unfinished'
            work.mkdir(parents=True)
            unfinished.mkdir(parents=True)
            old = work / 'Sequel - 13.mkv'
            new = work / 'Sequel - 14.mkv'
            extra = unfinished / 'Unfinished - 01.mkv'
            for path in (old, new, extra):
                path.write_bytes(b'video')

            old_target = os.path.join(
                '2026年10月新番', 'Sequel', 'Season 02', 'S02E01 - Sequel - 13.mkv'
            )
            rows = [base_row(str(old), 'Sequel', '2026年10月新番', 2, 1, 13, old_target)]
            planned, review = incremental.plan_new_rows(
                [], rows, tracked_source_roots=[str(source_root)]
            )

            self.assertEqual(review, [])
            self.assertEqual(len(planned), 1)
            self.assertEqual(planned[0]['SourcePath'], str(new))
            self.assertEqual(planned[0]['EpisodeStart'], '2')
            self.assertEqual(
                planned[0]['TargetRelativePath'],
                os.path.join('2026年10月新番', 'Sequel', 'Season 02', 'S02E02 - Sequel - 14.mkv'),
            )

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

    def test_dual_label_uses_absolute_number_for_next_season_episode(self):
        root = r'E:\Bangumi'
        work_root = root + r'\2026\2026-10\薬屋のひとりごと 第3期'
        old = work_root + r'\[BeanSub][Kusuriya S3][01_49][CHS].mp4'
        target = r'2026年10月新番\薬屋のひとりごと\Season 03\S03E01 - [BeanSub][Kusuriya S3][01_49][CHS].mp4'
        rows = [base_row(old, '薬屋のひとりごと', '2026年10月新番', 3, 1, 49, target)]
        profiles = incremental.build_profiles(rows, [root])

        new_path = work_root + r'\[BeanSub][Kusuriya S3][02_50][CHS].mp4'
        result = incremental.classify_new_path(new_path, profiles, rows)

        self.assertIsNotNone(result)
        self.assertEqual(result['Season'], '3')
        self.assertEqual(result['EpisodeStart'], '2')
        self.assertEqual(result['RawEpisodeLabel'], '50')
        self.assertIn(r'S03E02 - [BeanSub][Kusuriya S3][02_50]', result['TargetRelativePath'])

    def test_dual_label_rejects_conflicting_season_and_absolute_numbers(self):
        root = r'E:\Bangumi'
        work_root = root + r'\2026\2026-10\薬屋のひとりごと 第3期'
        old = work_root + r'\[BeanSub][Kusuriya S3][01_49][CHS].mp4'
        target = r'2026年10月新番\薬屋のひとりごと\Season 03\S03E01 - [BeanSub][Kusuriya S3][01_49][CHS].mp4'
        rows = [base_row(old, '薬屋のひとりごと', '2026年10月新番', 3, 1, 49, target)]
        profiles = incremental.build_profiles(rows, [root])

        conflicting_path = work_root + r'\[BeanSub][Kusuriya S3][03_50][CHS].mp4'
        self.assertIsNone(incremental.classify_new_path(conflicting_path, profiles, rows))

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

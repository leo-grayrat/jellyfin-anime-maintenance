import csv
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "build_jellyfin_full_canonical_view.py"
spec = importlib.util.spec_from_file_location("fcv", SCRIPT)
fcv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fcv)


class FullCanonicalViewTests(unittest.TestCase):
    def test_path_and_video_helpers(self):
        self.assertEqual(fcv.path_key(r"D:/Bangumi/Show/Ep.MKV"), r"d:\bangumi\show\ep.mkv")
        self.assertTrue(fcv.is_video(r"D:\Bangumi\Show\x.MKV"))
        self.assertFalse(fcv.is_video(r"D:\Bangumi\Show\x.ass"))
        self.assertTrue(fcv.path_under_or_equal(r"D:\Bangumi\Show\x.mkv", r"D:\Bangumi"))

    def test_load_targets_deduplicates_and_rejects_conflicts(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "targets.csv")
            fields = ["Work", "RuleId", "Action", "VideoPath", "Season", "Episode"]
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=fields)
                w.writeheader()
                w.writerow(dict(Work="A", RuleId="r1", Action="WRITE", VideoPath=r"D:\TV\ep.mkv", Season="1", Episode="2"))
                w.writerow(dict(Work="A", RuleId="r2", Action="WRITE", VideoPath=r"D:\TV\ep.mkv", Season="1", Episode="2"))
                w.writerow(dict(Work="A", RuleId="series-nfo", Action="WRITE", VideoPath=r"D:\TV\series.mkv", Season="1", Episode="1"))
            rows = fcv.load_targets(path, expected_count=1)
            self.assertEqual(rows[0]["expected_key"], "S01E02")

            with open(path, "a", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=fields)
                w.writerow(dict(Work="A", RuleId="r3", Action="WRITE", VideoPath=r"D:\TV\ep.mkv", Season="1", Episode="3"))
            with self.assertRaises(ValueError):
                fcv.load_targets(path, expected_count=-1)

    def test_mapping_renames_only_target_and_same_stem_sidecars(self):
        files = [
            {"library_name": "TV", "library_root": r"D:\Bangumi", "path": r"D:\Bangumi\Show\ep01.mkv", "size": 1},
            {"library_name": "TV", "library_root": r"D:\Bangumi", "path": r"D:\Bangumi\Show\ep01.ass", "size": 1},
            {"library_name": "TV", "library_root": r"D:\Bangumi", "path": r"D:\Bangumi\Show\ep01.nfo", "size": 1},
            {"library_name": "TV", "library_root": r"D:\Bangumi", "path": r"D:\Bangumi\Show\ep02.mkv", "size": 1},
            {"library_name": "TV", "library_root": r"D:\Bangumi", "path": r"D:\Bangumi\Show\poster.jpg", "size": 1},
        ]
        target = {
            "video_path": r"D:\Bangumi\Show\ep01.mkv",
            "path_key": fcv.path_key(r"D:\Bangumi\Show\ep01.mkv"),
            "expected_key": "S01E02",
            "season": 1,
            "episode": 2,
        }
        rows = fcv.build_mapping(files, [target], r"D:\Resource\BangumiLink\View")
        by_source = {fcv.path_key(x["source_path"]): x for x in rows}
        self.assertTrue(by_source[fcv.path_key(r"D:\Bangumi\Show\ep01.mkv")]["canonical_path"].endswith(r"S01E02 - ep01.mkv"))
        self.assertTrue(by_source[fcv.path_key(r"D:\Bangumi\Show\ep01.ass")]["canonical_path"].endswith(r"S01E02 - ep01.ass"))
        self.assertTrue(by_source[fcv.path_key(r"D:\Bangumi\Show\ep01.nfo")]["canonical_path"].endswith(r"S01E02 - ep01.nfo"))
        self.assertTrue(by_source[fcv.path_key(r"D:\Bangumi\Show\ep02.mkv")]["canonical_path"].endswith(r"ep02.mkv"))
        self.assertEqual(by_source[fcv.path_key(r"D:\Bangumi\Show\poster.jpg")]["role"], "PASSTHROUGH_FILE")

    def test_mapping_detects_collision(self):
        files = [
            {"library_name": "TV", "library_root": r"D:\A", "path": r"D:\A\same.mkv", "size": 1},
            {"library_name": "TV", "library_root": r"D:\B", "path": r"D:\B\same.mkv", "size": 1},
        ]
        with self.assertRaises(ValueError):
            fcv.build_mapping(files, [], r"D:\View")

    def test_virtual_folder_filtering_and_exclusions(self):
        folders = [
            {"Name": "TV A", "CollectionType": "tvshows", "Locations": [r"D:\Bangumi"]},
            {"Name": "Test", "CollectionType": "tvshows", "Locations": [r"C:\bangumi"]},
            {"Name": "Movies", "CollectionType": "movies", "Locations": [r"D:\Gekijouban"]},
            {"Name": "TV B", "CollectionType": "tvshows", "Locations": [r"E:\Anime"]},
        ]
        selected = fcv.select_production_locations(folders, fcv.DEFAULT_EXCLUDED_ROOTS)
        self.assertEqual([x["root"] for x in selected], [r"D:\Bangumi", r"E:\Anime"])


    def test_parent_of_excluded_root_is_not_silently_dropped(self):
        folders = [
            {"Name": "Too Broad", "CollectionType": "tvshows", "Locations": ["D:\\"]},
        ]
        with self.assertRaisesRegex(ValueError, "contains an excluded root"):
            fcv.select_production_locations(folders, fcv.DEFAULT_EXCLUDED_ROOTS)

    def test_expanded_episode_paths_are_paged_and_filtered_to_selected_roots(self):
        pages = [
            {
                "Items": [
                    {"Path": r"D:\Bangumi\A\a.mkv"},
                    {"Path": r"C:\bangumi\Test\x.mkv"},
                ],
                "TotalRecordCount": 3,
            },
            {
                "Items": [{"Path": r"E:\Anime\B\b.mkv"}],
                "TotalRecordCount": 3,
            },
        ]
        calls = []
        original = fcv.jellyfin_get

        def fake_get(server, api_key, path, query=None):
            calls.append((path, dict(query or {})))
            return pages[len(calls) - 1]

        fcv.jellyfin_get = fake_get
        try:
            roots = [
                {"library_name": "TV A", "root": r"D:\Bangumi"},
                {"library_name": "TV B", "root": r"E:\Anime"},
            ]
            paths = fcv.get_expanded_episode_paths("http://x", "secret", roots)
        finally:
            fcv.jellyfin_get = original

        self.assertEqual(paths, [r"D:\Bangumi\A\a.mkv", r"E:\Anime\B\b.mkv"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][1]["VideoTypes"], "VideoFile")
        self.assertEqual(calls[0][1]["IncludeItemTypes"], "Episode")

    def test_diff_paths(self):
        jellyfin_only, filesystem_only = fcv.diff_paths(
            [r"D:\TV\a.mkv", r"D:\TV\b.mkv"],
            [r"d:\tv\A.mkv", r"D:\TV\c.mkv"],
        )
        self.assertEqual(jellyfin_only, [r"D:\TV\c.mkv"])
        self.assertEqual(filesystem_only, [r"D:\TV\b.mkv"])


if __name__ == "__main__":
    unittest.main()

import csv
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "create_jellyfin_libraries_from_manifest.py"
spec = importlib.util.spec_from_file_location("libcreate", SCRIPT)
libcreate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libcreate)

FIELDS = ["SourcePath", "LibraryGroup", "CatalogBucket", "TargetRelativePath", "Status", "SourceVolume"]


def write_manifest(path, rows):
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


class LibraryPlanTests(unittest.TestCase):
    def test_groups_tv_and_movies_and_merges_volumes_with_original_names(self):
        with tempfile.TemporaryDirectory() as td:
            manifest = os.path.join(td, "manifest.csv")
            write_manifest(
                manifest,
                [
                    {
                        "SourcePath": r"C:\a.mkv",
                        "LibraryGroup": "2025年04月新番",
                        "CatalogBucket": "TV_MAIN",
                        "TargetRelativePath": r"2025年04月新番\A\Season 01\S01E01.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "C:",
                    },
                    {
                        "SourcePath": r"D:\b.mkv",
                        "LibraryGroup": "2025年04月新番",
                        "CatalogBucket": "TV_MAIN",
                        "TargetRelativePath": r"2025年04月新番\B\Season 01\S01E01.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "D:",
                    },
                    {
                        "SourcePath": r"D:\m.mkv",
                        "LibraryGroup": "剧场版",
                        "CatalogBucket": "MOVIE",
                        "TargetRelativePath": r"剧场版\M\M.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "D:",
                    },
                    {
                        "SourcePath": r"D:\old.mkv",
                        "LibraryGroup": "2022年动画",
                        "CatalogBucket": "TV_MAIN",
                        "TargetRelativePath": r"2022年动画\X\S01E01.mkv",
                        "Status": "IGNORE",
                        "SourceVolume": "D:",
                    },
                ],
            )
            plans = libcreate.plan_libraries(
                manifest,
                r"C:\resource\video\anime",
                r"D:\Resource\BangumiLink\View",
            )
            by_group = {row["group"]: row for row in plans}
            self.assertEqual(by_group["2025年04月新番"]["collection_type"], "tvshows")
            self.assertEqual(
                by_group["2025年04月新番"]["locations"],
                [
                    r"C:\resource\video\anime\2025年04月新番",
                    r"D:\Resource\BangumiLink\View\2025年04月新番",
                ],
            )
            self.assertEqual(by_group["2025年04月新番"]["name"], "2025年04月新番")
            self.assertEqual(by_group["剧场版"]["collection_type"], "movies")
            self.assertEqual(by_group["剧场版"]["name"], "剧场版")
            self.assertNotIn("2022年动画", by_group)

    def test_rejects_mixed_movie_tv_group(self):
        with tempfile.TemporaryDirectory() as td:
            manifest = os.path.join(td, "manifest.csv")
            write_manifest(
                manifest,
                [
                    {
                        "SourcePath": r"D:\a.mkv",
                        "LibraryGroup": "Mix",
                        "CatalogBucket": "TV_MAIN",
                        "TargetRelativePath": r"Mix\A.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "D:",
                    },
                    {
                        "SourcePath": r"D:\b.mkv",
                        "LibraryGroup": "Mix",
                        "CatalogBucket": "MOVIE",
                        "TargetRelativePath": r"Mix\B.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "D:",
                    },
                ],
            )
            with self.assertRaisesRegex(ValueError, "mixes TV and movie"):
                libcreate.plan_libraries(manifest, r"C:\x", r"D:\y")

    def test_rejects_target_group_mismatch(self):
        with tempfile.TemporaryDirectory() as td:
            manifest = os.path.join(td, "manifest.csv")
            write_manifest(
                manifest,
                [
                    {
                        "SourcePath": r"D:\a.mkv",
                        "LibraryGroup": "A",
                        "CatalogBucket": "TV_MAIN",
                        "TargetRelativePath": r"B\Show\S01E01.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "D:",
                    }
                ],
            )
            with self.assertRaisesRegex(ValueError, "does not start with LibraryGroup"):
                libcreate.plan_libraries(manifest, r"C:\x", r"D:\y")

    def test_provider_policy_prioritizes_tmdb_metadata_but_not_images(self):
        available = {
            "TypeOptions": [
                {
                    "Type": "Series",
                    "MetadataFetchers": [
                        {"Name": "The Open Movie Database", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "FanArt", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                        {"Name": "Dynamic Image Provider", "DefaultEnabled": True},
                    ],
                },
                {
                    "Type": "Episode",
                    "MetadataFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "The Open Movie Database", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "Screen Grabber", "DefaultEnabled": True},
                    ],
                },
            ]
        }
        options = libcreate.build_library_options(available)
        by_type = {row["Type"]: row for row in options["TypeOptions"]}

        series = by_type["Series"]
        self.assertEqual(series["MetadataFetcherOrder"][0], "TheMovieDb")
        self.assertEqual(series["MetadataFetchers"][0], "TheMovieDb")
        self.assertEqual(
            series["ImageFetcherOrder"],
            ["FanArt", "TheTVDB", "TheMovieDb", "Dynamic Image Provider"],
        )
        self.assertEqual(
            series["ImageFetchers"],
            ["FanArt", "TheTVDB", "TheMovieDb", "Dynamic Image Provider"],
        )

        episode = by_type["Episode"]
        self.assertEqual(
            episode["ImageFetcherOrder"],
            ["TheMovieDb", "Screen Grabber"],
        )

    def test_provider_policy_does_not_enable_default_disabled_plugins(self):
        available = {
            "TypeOptions": [
                {
                    "Type": "Movie",
                    "MetadataFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": False},
                        {"Name": "Other Metadata", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": False},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "Screen Grabber", "DefaultEnabled": True},
                    ],
                }
            ]
        }
        options = libcreate.build_library_options(available)
        movie = options["TypeOptions"][0]
        # TMDb is explicitly enabled for metadata by policy even if Jellyfin marks it off.
        self.assertEqual(movie["MetadataFetchers"][0], "TheMovieDb")
        # Other default-disabled image plugins are not silently enabled.
        self.assertNotIn("TheTVDB", movie["ImageFetchers"])
        self.assertEqual(movie["ImageFetchers"], ["TheMovieDb", "Screen Grabber"])

    def test_classify_existing_reusable_missing_conflict(self):
        plans = [
            {
                "group": "A",
                "name": "A",
                "collection_type": "tvshows",
                "locations": [r"D:\View\A"],
            },
            {
                "group": "B",
                "name": "B",
                "collection_type": "movies",
                "locations": [r"D:\View\B"],
            },
            {
                "group": "C",
                "name": "C",
                "collection_type": "tvshows",
                "locations": [r"D:\View\C"],
            },
        ]
        existing = [
            {"Name": "A", "CollectionType": "tvshows", "Locations": [r"d:\view\A"]},
            {"Name": "C", "CollectionType": "tvshows", "Locations": [r"D:\Other\C"]},
        ]
        classified = libcreate.classify_existing(plans, existing)
        self.assertEqual(
            {row["group"]: row["state"] for row in classified},
            {"A": "REUSABLE", "B": "MISSING", "C": "CONFLICT"},
        )
        with self.assertRaisesRegex(ValueError, "conflict"):
            libcreate.ensure_no_conflicts(classified)

    def test_apply_posts_missing_with_library_options_then_one_refresh(self):
        plans = [
            {
                "group": "A",
                "name": "A",
                "collection_type": "tvshows",
                "locations": [r"D:\View\A"],
                "library_options": {"EnableInternetProviders": True, "TypeOptions": []},
                "state": "MISSING",
                "reason": "",
            },
            {
                "group": "B",
                "name": "B",
                "collection_type": "movies",
                "locations": [r"D:\View\B"],
                "library_options": {"EnableInternetProviders": True, "TypeOptions": []},
                "state": "REUSABLE",
                "reason": "",
            },
        ]
        calls = []

        def fake_post(server, api_key, path, query=None, body=None):
            calls.append((path, query, body))

        result = libcreate.apply_libraries(plans, "http://x", "key", fake_post)
        self.assertEqual(result, {"created": 1, "reused": 1})
        self.assertEqual(calls[0][0], "/Library/VirtualFolders")
        self.assertEqual(calls[0][1]["name"], "A")
        self.assertEqual(calls[0][1]["refreshLibrary"], "false")
        self.assertEqual(
            calls[0][2],
            {"LibraryOptions": {"EnableInternetProviders": True, "TypeOptions": []}},
        )
        self.assertEqual(calls[-1], ("/Library/Refresh", None, None))


if __name__ == "__main__":
    unittest.main()

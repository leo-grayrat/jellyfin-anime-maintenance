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

    def test_tv_provider_policy_tmdb_metadata_tvdb_images(self):
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
                        {"Name": "TheTVDB", "DefaultEnabled": True},
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
        options = libcreate.build_library_options(available, "tvshows")
        by_type = {row["Type"]: row for row in options["TypeOptions"]}

        series = by_type["Series"]
        self.assertEqual(series["MetadataFetcherOrder"][0], "TheMovieDb")
        self.assertEqual(series["MetadataFetchers"][0], "TheMovieDb")
        self.assertEqual(series["ImageFetcherOrder"], ["TheTVDB", "TheMovieDb"])
        self.assertEqual(series["ImageFetchers"], ["TheTVDB", "TheMovieDb"])

        episode = by_type["Episode"]
        self.assertEqual(episode["ImageFetcherOrder"], ["TheMovieDb", "Screen Grabber"])

    def test_movie_image_provider_order_matches_confirmed_server_options(self):
        available = {
            "TypeOptions": [
                {
                    "Type": "Movie",
                    "MetadataFetchers": [
                        {"Name": "The Open Movie Database", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": False},
                        {"Name": "The Open Movie Database", "DefaultEnabled": True},
                        {"Name": "Embedded Image Extractor", "DefaultEnabled": False},
                        {"Name": "Screen Grabber", "DefaultEnabled": False},
                    ],
                }
            ]
        }
        options = libcreate.build_library_options(available, "movies")
        movie = options["TypeOptions"][0]
        self.assertEqual(movie["MetadataFetcherOrder"][0], "TheMovieDb")
        self.assertEqual(
            movie["ImageFetcherOrder"],
            [
                "TheTVDB",
                "The Open Movie Database",
                "TheMovieDb",
                "Embedded Image Extractor",
                "Screen Grabber",
            ],
        )
        self.assertEqual(
            movie["ImageFetchers"],
            [
                "TheTVDB",
                "The Open Movie Database",
                "TheMovieDb",
                "Embedded Image Extractor",
                "Screen Grabber",
            ],
        )

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

    def test_apply_posts_missing_without_starting_refresh(self):
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
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "/Library/VirtualFolders")
        self.assertEqual(calls[0][1]["name"], "A")
        self.assertEqual(calls[0][1]["refreshLibrary"], "false")
        self.assertEqual(
            calls[0][2],
            {"LibraryOptions": {"EnableInternetProviders": True, "TypeOptions": []}},
        )

    def test_verify_saved_libraries_checks_provider_lists(self):
        expected_options = {
            "EnableInternetProviders": True,
            "TypeOptions": [
                {
                    "Type": "Movie",
                    "MetadataFetchers": ["TheMovieDb", "TheTVDB"],
                    "MetadataFetcherOrder": ["TheMovieDb", "TheTVDB"],
                    "ImageFetchers": [
                        "TheTVDB",
                        "The Open Movie Database",
                        "TheMovieDb",
                        "Embedded Image Extractor",
                        "Screen Grabber",
                    ],
                    "ImageFetcherOrder": [
                        "TheTVDB",
                        "The Open Movie Database",
                        "TheMovieDb",
                        "Embedded Image Extractor",
                        "Screen Grabber",
                    ],
                }
            ],
        }
        plans = [
            {
                "name": "剧场版",
                "collection_type": "movies",
                "locations": [r"D:\View\剧场版"],
                "library_options": expected_options,
            }
        ]
        good = [
            {
                "Name": "剧场版",
                "CollectionType": "movies",
                "Locations": [r"D:\View\剧场版"],
                "LibraryOptions": expected_options,
            }
        ]
        libcreate.verify_saved_libraries(plans, good)

        bad_options = {
            "EnableInternetProviders": True,
            "TypeOptions": [
                {
                    "Type": "Movie",
                    "MetadataFetchers": ["TheMovieDb", "TheTVDB"],
                    "MetadataFetcherOrder": ["TheMovieDb", "TheTVDB"],
                    "ImageFetchers": ["TheTVDB", "TheMovieDb"],
                    "ImageFetcherOrder": ["TheTVDB", "TheMovieDb"],
                }
            ],
        }
        bad = [
            {
                "Name": "剧场版",
                "CollectionType": "movies",
                "Locations": [r"D:\View\剧场版"],
                "LibraryOptions": bad_options,
            }
        ]
        with self.assertRaisesRegex(ValueError, "saved library verification failed"):
            libcreate.verify_saved_libraries(plans, bad)


if __name__ == "__main__":
    unittest.main()

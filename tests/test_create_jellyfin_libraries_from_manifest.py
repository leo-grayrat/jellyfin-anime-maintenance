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
            self.assertEqual(by_group["剧场版"]["collection_type"], "movies")
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

    def test_tv_provider_policy_keeps_metadata_order_but_prefers_tmdb_images(self):
        available = {
            "TypeOptions": [
                {
                    "Type": "Series",
                    "MetadataFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                    ],
                },
                {
                    "Type": "Season",
                    "MetadataFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                    ],
                },
                {
                    "Type": "Episode",
                    "MetadataFetchers": [
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "Screen Grabber", "DefaultEnabled": True},
                    ],
                },
            ]
        }
        options = libcreate.build_library_options(available, "tvshows")
        by_type = {row["Type"]: row for row in options["TypeOptions"]}

        for type_name in ("Series", "Season", "Episode"):
            row = by_type[type_name]
            self.assertEqual(row["MetadataFetcherOrder"][:2], ["TheMovieDb", "TheTVDB"])
            self.assertEqual(row["MetadataFetchers"][:2], ["TheMovieDb", "TheTVDB"])
            self.assertEqual(row["ImageFetcherOrder"][:2], ["TheMovieDb", "TheTVDB"])
            self.assertEqual(row["ImageFetchers"][:2], ["TheMovieDb", "TheTVDB"])

        self.assertEqual(
            by_type["Episode"]["ImageFetcherOrder"],
            ["TheMovieDb", "TheTVDB", "Screen Grabber"],
        )

    def test_movie_provider_policy_tmdb_first_for_metadata_and_images(self):
        available = {
            "TypeOptions": [
                {
                    "Type": "Movie",
                    "MetadataFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": True},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                    ],
                    "ImageFetchers": [
                        {"Name": "TheTVDB", "DefaultEnabled": False},
                        {"Name": "TheMovieDb", "DefaultEnabled": True},
                        {"Name": "The Open Movie Database", "DefaultEnabled": True},
                        {"Name": "Embedded Image Extractor", "DefaultEnabled": False},
                        {"Name": "Screen Grabber", "DefaultEnabled": False},
                    ],
                }
            ]
        }
        movie = libcreate.build_library_options(available, "movies")["TypeOptions"][0]
        self.assertEqual(movie["MetadataFetcherOrder"][:2], ["TheMovieDb", "TheTVDB"])
        self.assertEqual(
            movie["ImageFetcherOrder"],
            [
                "TheMovieDb",
                "TheTVDB",
                "The Open Movie Database",
                "Embedded Image Extractor",
                "Screen Grabber",
            ],
        )
        self.assertEqual(movie["ImageFetchers"], movie["ImageFetcherOrder"])

    def test_classify_existing_reusable_missing_conflict(self):
        plans = [
            {"name": "A", "collection_type": "tvshows", "locations": [r"D:\View\A"]},
            {"name": "B", "collection_type": "movies", "locations": [r"D:\View\B"]},
            {"name": "C", "collection_type": "tvshows", "locations": [r"D:\View\C"]},
        ]
        existing = [
            {"Name": "A", "CollectionType": "tvshows", "Locations": [r"d:\view\A"]},
            {"Name": "C", "CollectionType": "tvshows", "Locations": [r"D:\Other\C"]},
        ]
        classified = libcreate.classify_existing(plans, existing)
        self.assertEqual(
            {row["name"]: row["state"] for row in classified},
            {"A": "REUSABLE", "B": "MISSING", "C": "CONFLICT"},
        )

    def test_delete_reusable_libraries_only_deletes_safe_manifest_matches(self):
        plans = [
            {"name": "A", "state": "REUSABLE"},
            {"name": "B", "state": "MISSING"},
        ]
        calls = []

        def fake_delete(server, api_key, path, query=None):
            calls.append((path, query))

        deleted = libcreate.delete_reusable_libraries(
            plans,
            "http://x",
            "key",
            delete=fake_delete,
        )
        self.assertEqual(deleted, 1)
        self.assertEqual(
            calls,
            [("/Library/VirtualFolders", {"name": "A", "refreshLibrary": "false"})],
        )

    def test_apply_posts_missing_without_starting_refresh(self):
        plans = [
            {
                "name": "A",
                "collection_type": "tvshows",
                "locations": [r"D:\View\A"],
                "library_options": {"EnableInternetProviders": True, "TypeOptions": []},
                "state": "MISSING",
            },
            {
                "name": "B",
                "collection_type": "movies",
                "locations": [r"D:\View\B"],
                "library_options": {"EnableInternetProviders": True, "TypeOptions": []},
                "state": "REUSABLE",
            },
        ]
        calls = []

        def fake_post(server, api_key, path, query=None, body=None):
            calls.append((path, query, body))

        result = libcreate.apply_libraries(plans, "http://x", "key", fake_post)
        self.assertEqual(result, {"created": 1, "reused": 1})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "/Library/VirtualFolders")
        self.assertEqual(calls[0][1]["refreshLibrary"], "false")


if __name__ == "__main__":
    unittest.main()

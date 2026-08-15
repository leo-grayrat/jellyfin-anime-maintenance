from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import disable_jellyfin_missing_episode_fetcher as disable


class DisableMissingEpisodeFetcherTests(unittest.TestCase):
    def test_remove_missing_episode_fetcher_preserves_other_fetchers(self) -> None:
        options = {
            "TypeOptions": [
                {
                    "Type": "Series",
                    "MetadataFetchers": ["TheTVDB", "Missing Episode Fetcher", "TheMovieDb"],
                    "ImageFetchers": ["TheTVDB", "TheMovieDb"],
                },
                {
                    "Type": "Episode",
                    "MetadataFetchers": ["TheTVDB", "TheMovieDb", "The Open Movie Database"],
                },
            ],
            "PreferredMetadataLanguage": "zh-CN",
        }

        updated, removed = disable.remove_missing_episode_fetcher(options)

        self.assertEqual(removed, 1)
        self.assertEqual(
            updated["TypeOptions"][0]["MetadataFetchers"],
            ["TheTVDB", "TheMovieDb"],
        )
        self.assertEqual(
            updated["TypeOptions"][0]["ImageFetchers"],
            ["TheTVDB", "TheMovieDb"],
        )
        self.assertEqual(
            updated["TypeOptions"][1]["MetadataFetchers"],
            ["TheTVDB", "TheMovieDb", "The Open Movie Database"],
        )
        self.assertEqual(updated["PreferredMetadataLanguage"], "zh-CN")
        self.assertIn("Missing Episode Fetcher", options["TypeOptions"][0]["MetadataFetchers"])

    def test_build_plan_targets_only_direct_view_group_libraries(self) -> None:
        folders = [
            {
                "Name": "2025年04月新番",
                "ItemId": "a",
                "CollectionType": "tvshows",
                "Locations": [r"D:\Resource\BangumiLink\View-v3\2025年4月新番"],
                "LibraryOptions": {
                    "TypeOptions": [
                        {"Type": "Series", "MetadataFetchers": ["TheTVDB", "Missing Episode Fetcher"]}
                    ]
                },
            },
            {
                "Name": "2026年01月新番",
                "ItemId": "b",
                "CollectionType": "tvshows",
                "Locations": [r"D:\Resource\BangumiLink\View-v3\2026年1月新番"],
                "LibraryOptions": {
                    "TypeOptions": [
                        {"Type": "Series", "MetadataFetchers": ["TheTVDB", "TheMovieDb"]}
                    ]
                },
            },
            {
                "Name": "raw",
                "ItemId": "raw",
                "CollectionType": "tvshows",
                "Locations": [r"D:\Resource\BangumiLink\View-v3"],
                "LibraryOptions": {
                    "TypeOptions": [
                        {"Type": "Series", "MetadataFetchers": ["Missing Episode Fetcher"]}
                    ]
                },
            },
            {
                "Name": "外部正式库",
                "ItemId": "c",
                "CollectionType": "tvshows",
                "Locations": [r"C:\bangumi"],
                "LibraryOptions": {
                    "TypeOptions": [
                        {"Type": "Series", "MetadataFetchers": ["Missing Episode Fetcher"]}
                    ]
                },
            },
        ]

        plan = disable.build_plan(folders, r"D:\Resource\BangumiLink\View-v3")

        self.assertEqual([row["name"] for row in plan], ["2025年04月新番", "2026年01月新番"])
        self.assertEqual(plan[0]["state"], "UPDATE")
        self.assertEqual(plan[0]["removed"], 1)
        self.assertEqual(plan[1]["state"], "SKIP")
        self.assertEqual(plan[1]["removed"], 0)

    def test_apply_plan_updates_only_changed_libraries_without_refresh(self) -> None:
        calls = []

        def fake_request(server, api_key, method, path, query=None, body=None):
            calls.append({"method": method, "path": path, "query": query, "body": body})
            return None

        plan = [
            {
                "name": "A",
                "item_id": "id-a",
                "state": "UPDATE",
                "removed": 1,
                "updated_options": {"TypeOptions": []},
            },
            {
                "name": "B",
                "item_id": "id-b",
                "state": "SKIP",
                "removed": 0,
                "updated_options": {"TypeOptions": []},
            },
        ]

        changed = disable.apply_plan(
            "http://127.0.0.1:8096",
            "secret",
            plan,
            request_fn=fake_request,
        )

        self.assertEqual(changed, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "POST")
        self.assertEqual(calls[0]["path"], "/Library/VirtualFolders/LibraryOptions")
        self.assertEqual(calls[0]["body"]["Id"], "id-a")
        self.assertEqual(calls[0]["body"]["LibraryOptions"], {"TypeOptions": []})


if __name__ == "__main__":
    unittest.main()

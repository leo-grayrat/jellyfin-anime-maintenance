from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import create_jellyfin_grouped_libraries as grouped


class GroupedLibraryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.template = {
            "Name": "模板",
            "CollectionType": "tvshows",
            "Locations": [r"D:\Resource\BangumiLink\View-v3"],
            "LibraryOptions": {
                "EnableInternetProviders": True,
                "PreferredMetadataLanguage": "zh-CN",
                "MetadataCountryCode": "CN",
                "MetadataFetchers": ["TheTVDB", "TheMovieDb", "OMDb"],
                "PathInfos": [{"Path": r"D:\Resource\BangumiLink\View-v3"}],
            },
        }

    def test_format_group_library_name_pads_single_digit_months(self) -> None:
        self.assertEqual(grouped.format_group_library_name("2025年1月新番"), "2025年01月新番")
        self.assertEqual(grouped.format_group_library_name("2025年4月新番"), "2025年04月新番")
        self.assertEqual(grouped.format_group_library_name("2025年7月新番"), "2025年07月新番")
        self.assertEqual(grouped.format_group_library_name("2025年10月新番"), "2025年10月新番")
        self.assertEqual(grouped.format_group_library_name("2017年动画"), "2017年动画")

    def test_clone_library_options_replaces_only_path_infos(self) -> None:
        original = copy.deepcopy(self.template["LibraryOptions"])
        target = r"D:\Resource\BangumiLink\View-v3\2026年1月新番"
        cloned = grouped.clone_library_options(original, target)

        self.assertEqual(cloned["PreferredMetadataLanguage"], "zh-CN")
        self.assertEqual(cloned["MetadataFetchers"][0], "TheTVDB")
        self.assertEqual(cloned["PathInfos"], [{"Path": target}])
        self.assertEqual(original["PathInfos"], [{"Path": r"D:\Resource\BangumiLink\View-v3"}])

    def test_build_plan_skips_same_name_same_path(self) -> None:
        target = {"name": "2026年01月新番", "path": r"D:\View-v3\2026年1月新番"}
        existing = [{
            "Name": "2026年01月新番",
            "CollectionType": "tvshows",
            "Locations": [r"D:\View-v3\2026年1月新番"],
        }]
        plan = grouped.build_plan([target], existing)
        self.assertEqual(plan[0]["state"], "SKIP")

    def test_build_plan_rejects_same_name_different_path(self) -> None:
        target = {"name": "2026年01月新番", "path": r"D:\View-v3\2026年1月新番"}
        existing = [{
            "Name": "2026年01月新番",
            "CollectionType": "tvshows",
            "Locations": [r"D:\Old\2026年1月新番"],
        }]
        with self.assertRaisesRegex(ValueError, "same library name"):
            grouped.build_plan([target], existing)

    def test_build_plan_rejects_same_path_different_name(self) -> None:
        target = {"name": "2026年01月新番", "path": r"D:\View-v3\2026年1月新番"}
        existing = [{
            "Name": "另一个名字",
            "CollectionType": "tvshows",
            "Locations": [r"D:\View-v3\2026年1月新番"],
        }]
        with self.assertRaisesRegex(ValueError, "same library path"):
            grouped.build_plan([target], existing)

    def test_build_plan_allows_same_path_when_owner_is_template(self) -> None:
        target = {"name": "2026年01月新番", "path": r"D:\View-v3\2026年1月新番"}
        existing = [{
            "Name": "raw",
            "CollectionType": "tvshows",
            "Locations": [r"D:\View-v3\2026年1月新番"],
        }]
        plan = grouped.build_plan([target], existing, template_name="raw")
        self.assertEqual(plan[0]["state"], "CREATE")

    def test_build_plan_still_rejects_non_template_owner(self) -> None:
        target = {"name": "2026年01月新番", "path": r"D:\View-v3\2026年1月新番"}
        existing = [
            {
                "Name": "raw",
                "CollectionType": "tvshows",
                "Locations": [r"D:\View-v3\2026年1月新番"],
            },
            {
                "Name": "别的库",
                "CollectionType": "tvshows",
                "Locations": [r"D:\View-v3\2026年1月新番"],
            },
        ]
        with self.assertRaisesRegex(ValueError, "same library path"):
            grouped.build_plan([target], existing, template_name="raw")

    def test_apply_plan_creates_each_missing_library_and_refreshes_once(self) -> None:
        calls = []

        def fake_request(server, api_key, method, path, query=None, body=None):
            calls.append({"method": method, "path": path, "query": query, "body": body})
            return None

        options = self.template["LibraryOptions"]
        plan = [
            {"name": "A", "path": r"D:\View-v3\A", "state": "CREATE"},
            {"name": "B", "path": r"D:\View-v3\B", "state": "CREATE"},
            {"name": "C", "path": r"D:\View-v3\C", "state": "SKIP"},
        ]
        created = grouped.apply_plan(
            "http://127.0.0.1:8096",
            "secret",
            options,
            plan,
            request_fn=fake_request,
        )

        self.assertEqual(created, 2)
        creates = [c for c in calls if c["path"] == "/Library/VirtualFolders"]
        refreshes = [c for c in calls if c["path"] == "/Library/Refresh"]
        self.assertEqual(len(creates), 2)
        self.assertEqual(len(refreshes), 1)
        self.assertEqual(creates[0]["query"]["name"], "A")
        self.assertEqual(creates[0]["query"]["collectionType"], "tvshows")
        self.assertEqual(creates[0]["query"]["paths"], [r"D:\View-v3\A"])
        self.assertEqual(creates[0]["body"]["LibraryOptions"]["PathInfos"], [{"Path": r"D:\View-v3\A"}])
        self.assertNotIn(r"D:\Resource\BangumiLink\View-v3", str(creates[0]["body"]))


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import audit_jellyfin_series_identity as audit


class SeriesIdentityAuditTests(unittest.TestCase):
    def test_classify_series(self) -> None:
        self.assertEqual(audit.classify_series({"ProviderIds": {"Tvdb": "1"}, "ImageTags": {"Primary": "x"}}), "OK")
        self.assertEqual(audit.classify_series({"ProviderIds": {}, "ImageTags": {"Primary": "x"}}), "NO_TVDB_ID")
        self.assertEqual(audit.classify_series({"ProviderIds": {"Tvdb": "1"}, "ImageTags": {}}), "NO_PRIMARY_IMAGE")
        self.assertEqual(audit.classify_series({"ProviderIds": {}, "ImageTags": {}}), "NO_TVDB_AND_IMAGE")

    def test_path_derived_name_detection(self) -> None:
        self.assertTrue(
            audit.name_looks_path_derived(
                "[Prejudice-Studio] 前桥魔女 Maebashi Witches [01-12]",
                r"D:\View-v3\2025年4月新番\[Prejudice-Studio] 前桥魔女 Maebashi Witches [01-12]",
                is_file=False,
            )
        )
        self.assertFalse(
            audit.name_looks_path_derived(
                "前桥魔女",
                r"D:\View-v3\2025年4月新番\[Prejudice-Studio] 前桥魔女 Maebashi Witches [01-12]",
                is_file=False,
            )
        )
        self.assertTrue(
            audit.name_looks_path_derived(
                "前桥魔女 Maebashi Witches - 01 [Bilibili]",
                r"D:\View-v3\Show\Season 01\[Prejudice-Studio] 前桥魔女 Maebashi Witches - 01 [Bilibili].mkv",
                is_file=True,
            )
        )

    def test_choose_library_prefers_most_specific_root(self) -> None:
        roots = [
            {"library_name": "模板", "root": r"D:\View-v3"},
            {"library_name": "2026年01月新番", "root": r"D:\View-v3\2026年1月新番"},
        ]
        chosen = audit.choose_library(r"D:\View-v3\2026年1月新番\Foo", roots)
        self.assertEqual(chosen["library_name"], "2026年01月新番")

    def test_build_rows_reports_identity_and_text_regression_signals(self) -> None:
        series = [
            {
                "Id": "s1-new",
                "Name": "[Group] Series 1 [01-02]",
                "Path": r"D:\View-v3\2025年4月新番\[Group] Series 1 [01-02]",
                "ProductionYear": 2025,
                "ProviderIds": {},
                "ImageTags": {"Primary": "img"},
                "Overview": "",
                "DateLastRefreshed": "2026-08-15T05:00:00Z",
                "DateLastSaved": "2026-08-15T05:01:00Z",
            },
            {
                "Id": "outside",
                "Name": "Outside",
                "Path": r"C:\bangumi\Outside",
                "ProductionYear": 2020,
                "ProviderIds": {"Tvdb": "999"},
                "ImageTags": {"Primary": "img"},
            },
        ]
        episodes = [
            {
                "Id": "e1",
                "SeriesId": "s1-new",
                "Name": "Series 1 - 01 [1080p]",
                "Path": r"D:\View-v3\2025年4月新番\[Group] Series 1 [01-02]\Season 01\[Group] Series 1 - 01 [1080p].mkv",
                "ProviderIds": {},
                "Overview": "",
            },
            {
                "Id": "e2",
                "SeriesId": "s1-new",
                "Name": "The Remote Episode Title",
                "Path": r"D:\View-v3\2025年4月新番\[Group] Series 1 [01-02]\Season 01\[Group] Series 1 - 02 [1080p].mkv",
                "ProviderIds": {"Tvdb": "12345"},
                "Overview": "remote overview",
            },
        ]
        roots = [
            {"library_name": "2025年04月新番", "root": r"D:\View-v3\2025年4月新番"},
        ]
        previous = {
            audit.path_key(r"D:\View-v3\2025年4月新番\[Group] Series 1 [01-02]"): {
                "SeriesId": "s1-old",
                "SeriesName": "Series 1",
                "TvdbId": "100",
            }
        }

        rows = audit.build_rows(series, episodes, roots, r"D:\View-v3", previous_rows=previous)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["SeriesId"], "s1-new")
        self.assertEqual(row["PreviousSeriesId"], "s1-old")
        self.assertTrue(row["ItemIdChanged"])
        self.assertEqual(row["PreviousTvdbId"], "100")
        self.assertTrue(row["SeriesNameLooksLocal"])
        self.assertEqual(row["EpisodeCount"], 2)
        self.assertEqual(row["EpisodeWithTvdbIdCount"], 1)
        self.assertEqual(row["EpisodeWithOverviewCount"], 1)
        self.assertEqual(row["EpisodeNameLooksLocalCount"], 1)
        self.assertIn("ITEM_ID_CHANGED", row["RegressionSignals"])
        self.assertIn("TVDB_ID_LOST", row["RegressionSignals"])
        self.assertIn("SERIES_NAME_LOOKS_LOCAL", row["RegressionSignals"])
        self.assertIn("EPISODE_NAMES_LOOK_LOCAL", row["RegressionSignals"])


if __name__ == "__main__":
    unittest.main()

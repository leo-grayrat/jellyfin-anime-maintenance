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

    def test_choose_library_prefers_most_specific_root(self) -> None:
        roots = [
            {"library_name": "模板", "root": r"D:\View-v3"},
            {"library_name": "2026年1月新番", "root": r"D:\View-v3\2026年1月新番"},
        ]
        chosen = audit.choose_library(r"D:\View-v3\2026年1月新番\Foo", roots)
        self.assertEqual(chosen["library_name"], "2026年1月新番")

    def test_build_rows_counts_episodes_and_filters_outside_view(self) -> None:
        series = [
            {
                "Id": "s1",
                "Name": "Series 1",
                "Path": r"D:\View-v3\2026年1月新番\Series 1",
                "ProductionYear": 2026,
                "ProviderIds": {"Tvdb": "100", "Tmdb": "200", "Imdb": "tt1"},
                "ImageTags": {"Primary": "img"},
            },
            {
                "Id": "s2",
                "Name": "Series 2",
                "Path": r"D:\View-v3\2026年4月新番\Series 2",
                "ProductionYear": 2026,
                "ProviderIds": {},
                "ImageTags": {},
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
            {"SeriesId": "s1"},
            {"SeriesId": "s1"},
            {"SeriesId": "s2"},
            {"SeriesId": "outside"},
        ]
        roots = [
            {"library_name": "模板", "root": r"D:\View-v3"},
            {"library_name": "2026年1月新番", "root": r"D:\View-v3\2026年1月新番"},
            {"library_name": "2026年4月新番", "root": r"D:\View-v3\2026年4月新番"},
        ]

        rows = audit.build_rows(series, episodes, roots, r"D:\View-v3")
        self.assertEqual(len(rows), 2)
        by_id = {row["SeriesId"]: row for row in rows}
        self.assertEqual(by_id["s1"]["LibraryName"], "2026年1月新番")
        self.assertEqual(by_id["s1"]["EpisodeCount"], 2)
        self.assertEqual(by_id["s1"]["Status"], "OK")
        self.assertEqual(by_id["s2"]["EpisodeCount"], 1)
        self.assertEqual(by_id["s2"]["Status"], "NO_TVDB_AND_IMAGE")
        self.assertEqual(by_id["s1"]["TvdbId"], "100")
        self.assertEqual(by_id["s1"]["TmdbId"], "200")
        self.assertEqual(by_id["s1"]["ImdbId"], "tt1")


if __name__ == "__main__":
    unittest.main()

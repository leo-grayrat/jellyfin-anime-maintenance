from __future__ import annotations

import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import write_jellyfin_series_identity_nfos as writer


class SeriesIdentityNfoTests(unittest.TestCase):
    def test_builtin_identity_table_is_exact(self) -> None:
        rows = {row["title"]: row for row in writer.SERIES_IDENTITIES}
        self.assertEqual(len(rows), 7)
        self.assertEqual(
            (rows["幼女战记"]["tvdb"], rows["幼女战记"]["tmdb"], rows["幼女战记"]["imdb"]),
            ("315500", "69346", "tt6455986"),
        )
        self.assertEqual(
            (
                rows["偶像大师 灰姑娘女孩 U149"]["tvdb"],
                rows["偶像大师 灰姑娘女孩 U149"]["tmdb"],
                rows["偶像大师 灰姑娘女孩 U149"]["imdb"],
            ),
            ("424278", "216391", "tt26699386"),
        )
        self.assertEqual(
            (rows["前桥魔女"]["tvdb"], rows["前桥魔女"]["tmdb"], rows["前桥魔女"]["imdb"]),
            ("454132", "270602", "tt35351289"),
        )
        self.assertEqual(
            (
                rows["克雷瓦提斯-魔兽之王与婴儿与尸之勇者-"]["tvdb"],
                rows["克雷瓦提斯-魔兽之王与婴儿与尸之勇者-"]["tmdb"],
                rows["克雷瓦提斯-魔兽之王与婴儿与尸之勇者-"]["imdb"],
            ),
            ("451793", "258348", "tt32991344"),
        )
        self.assertEqual(
            (rows["瑠璃的宝石"]["tvdb"], rows["瑠璃的宝石"]["tmdb"], rows["瑠璃的宝石"]["imdb"]),
            ("454330", "271649", "tt37113118"),
        )
        self.assertEqual(
            (rows["藤本树 17-26"]["tvdb"], rows["藤本树 17-26"]["tmdb"], rows["藤本树 17-26"]["imdb"]),
            ("467641", "299778", "tt38491451"),
        )
        self.assertEqual(
            (rows["SPY×FAMILY"]["tvdb"], rows["SPY×FAMILY"]["tmdb"], rows["SPY×FAMILY"]["imdb"]),
            ("405920", "120089", "tt13706018"),
        )

    def test_render_nfo_contains_only_title_and_three_ids(self) -> None:
        entry = {
            "title": "A & B",
            "tvdb": "1",
            "tmdb": "2",
            "imdb": "tt3",
        }
        text = writer.render_nfo(entry)
        root = ET.fromstring(text)

        self.assertEqual(root.tag, "tvshow")
        self.assertEqual([child.tag for child in root], ["title", "uniqueid", "uniqueid", "uniqueid"])
        self.assertEqual(root.findtext("title"), "A & B")
        ids = [(node.attrib.get("type"), node.text) for node in root.findall("uniqueid")]
        self.assertEqual(ids, [("tvdb", "1"), ("tmdb", "2"), ("imdb", "tt3")])
        self.assertNotIn("displayorder", text.casefold())
        self.assertNotIn("overview", text.casefold())
        self.assertTrue(text.endswith("\n"))

    def test_build_plan_locates_one_direct_child_by_group_and_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "2025年7月新番"
            series = group / "[Group] Example [01-12]"
            series.mkdir(parents=True)
            entries = [self._entry("2025年7月新番", "[Group] Example", "示例")]

            plan = writer.build_plan(tmp, entries)

            self.assertEqual(len(plan), 1)
            self.assertEqual(plan[0]["state"], "CREATE")
            self.assertEqual(Path(plan[0]["series_dir"]), series)
            self.assertEqual(Path(plan[0]["nfo_path"]), series / "tvshow.nfo")

    def test_build_plan_rejects_missing_or_ambiguous_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "2025年7月新番"
            group.mkdir(parents=True)
            entry = self._entry("2025年7月新番", "[Group] Example", "示例")

            with self.assertRaisesRegex(ValueError, "expected exactly one directory"):
                writer.build_plan(tmp, [entry])

            (group / "[Group] Example A").mkdir()
            (group / "[Group] Example B").mkdir()
            with self.assertRaisesRegex(ValueError, "expected exactly one directory"):
                writer.build_plan(tmp, [entry])

    def test_build_plan_marks_reuse_and_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "2025年7月新番"
            series = group / "[Group] Example [01-12]"
            series.mkdir(parents=True)
            entry = self._entry("2025年7月新番", "[Group] Example", "示例")
            nfo = series / "tvshow.nfo"

            nfo.write_text(writer.render_nfo(entry), encoding="utf-8")
            self.assertEqual(writer.build_plan(tmp, [entry])[0]["state"], "REUSE")

            nfo.write_text("<tvshow><title>其他内容</title></tvshow>\n", encoding="utf-8")
            row = writer.build_plan(tmp, [entry])[0]
            self.assertEqual(row["state"], "CONFLICT")

    def test_apply_plan_refuses_entire_batch_when_any_conflict_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "组"
            series_a = group / "A release"
            series_b = group / "B release"
            series_a.mkdir(parents=True)
            series_b.mkdir(parents=True)
            entries = [
                self._entry("组", "A release", "A"),
                self._entry("组", "B release", "B"),
            ]
            (series_b / "tvshow.nfo").write_text("<tvshow><title>冲突</title></tvshow>\n", encoding="utf-8")
            plan = writer.build_plan(tmp, entries)

            with self.assertRaisesRegex(RuntimeError, "CONFLICT"):
                writer.apply_plan(plan)

            self.assertFalse((series_a / "tvshow.nfo").exists())
            self.assertEqual((series_b / "tvshow.nfo").read_text(encoding="utf-8"), "<tvshow><title>冲突</title></tvshow>\n")

    def test_apply_writes_then_second_plan_is_all_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "组"
            series_a = group / "A release"
            series_b = group / "B release"
            series_a.mkdir(parents=True)
            series_b.mkdir(parents=True)
            entries = [
                self._entry("组", "A release", "A"),
                self._entry("组", "B release", "B"),
            ]

            first_plan = writer.build_plan(tmp, entries)
            self.assertEqual([row["state"] for row in first_plan], ["CREATE", "CREATE"])
            self.assertEqual(writer.apply_plan(first_plan), 2)

            for row in first_plan:
                self.assertEqual(Path(row["nfo_path"]).read_text(encoding="utf-8"), row["expected_content"])
                self.assertFalse(Path(str(row["nfo_path"]) + ".tmp").exists())

            second_plan = writer.build_plan(tmp, entries)
            self.assertEqual([row["state"] for row in second_plan], ["REUSE", "REUSE"])
            self.assertEqual(writer.apply_plan(second_plan), 0)

    @staticmethod
    def _entry(group: str, prefix: str, title: str) -> dict:
        return {
            "group": group,
            "directory_prefix": prefix,
            "title": title,
            "tvdb": "100",
            "tmdb": "200",
            "imdb": "tt300",
        }


if __name__ == "__main__":
    unittest.main()

import csv
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "apply_anime_decision_manifest.py"
spec = importlib.util.spec_from_file_location("manifest_apply", SCRIPT)
manifest_apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest_apply)

FIELDS = [
    "SourcePath",
    "WorkTitle",
    "LibraryGroup",
    "CatalogBucket",
    "MediaClass",
    "Season",
    "EpisodeStart",
    "EpisodeEnd",
    "RawEpisodeLabel",
    "SpecialType",
    "VersionGroup",
    "VersionRole",
    "TargetRelativePath",
    "DecisionBasis",
    "Status",
    "Confidence",
    "SourceVolume",
    "EvidenceURL",
    "Notes",
]


def write_manifest(path, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


class AnimeDecisionManifestExecutorTests(unittest.TestCase):
    def test_load_manifest_skips_ignore_and_does_not_parse_episode_fields(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "manifest.csv"
            source = Path(td) / "source.mkv"
            source.write_bytes(b"abc")
            write_manifest(
                path,
                [
                    {
                        "SourcePath": str(source),
                        "WorkTitle": "Example",
                        "LibraryGroup": "2026年动画",
                        "CatalogBucket": "TV_MAIN",
                        "MediaClass": "TV_EPISODE",
                        "Season": "999",
                        "EpisodeStart": "not-used",
                        "EpisodeEnd": "also-not-used",
                        "TargetRelativePath": r"2026年动画\Example\Season 01\S01E01 - source.mkv",
                        "Status": "CONFIRMED",
                        "SourceVolume": "",
                    },
                    {
                        "SourcePath": str(Path(td) / "ignored.mkv"),
                        "WorkTitle": "Ignored",
                        "LibraryGroup": "2022年动画",
                        "CatalogBucket": "TV_MAIN",
                        "MediaClass": "TV_EPISODE",
                        "TargetRelativePath": "",
                        "Status": "IGNORE",
                        "SourceVolume": "",
                    },
                ],
            )
            active, ignored = manifest_apply.load_manifest(str(path))
            self.assertEqual(len(active), 1)
            self.assertEqual(len(ignored), 1)
            self.assertEqual(active[0]["SourcePath"], str(source))

    def test_load_manifest_rejects_target_traversal_and_duplicate_source(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "manifest.csv"
            src = str(Path(td) / "a.mkv")
            base = {
                "SourcePath": src,
                "WorkTitle": "A",
                "LibraryGroup": "TV",
                "CatalogBucket": "TV_MAIN",
                "MediaClass": "TV_EPISODE",
                "Status": "CONFIRMED",
                "SourceVolume": "",
            }
            write_manifest(path, [{**base, "TargetRelativePath": r"..\escape.mkv"}])
            with self.assertRaisesRegex(ValueError, "relative path"):
                manifest_apply.load_manifest(str(path))

            write_manifest(
                path,
                [
                    {**base, "TargetRelativePath": r"TV\a.mkv"},
                    {**base, "TargetRelativePath": r"TV\b.mkv"},
                ],
            )
            with self.assertRaisesRegex(ValueError, "duplicate SourcePath"):
                manifest_apply.load_manifest(str(path))

    def test_build_plan_uses_source_volume_root_and_requires_d_root(self):
        rows = [
            {
                "SourcePath": r"C:\bangumi\a.mkv",
                "TargetRelativePath": r"2026年动画\A\Season 01\S01E01 - a.mkv",
                "Status": "CONFIRMED",
                "SourceVolume": "C:",
            },
            {
                "SourcePath": r"D:\Bangumi\b.mkv",
                "TargetRelativePath": r"2026年动画\B\Season 01\S01E01 - b.mkv",
                "Status": "CONFIRMED",
                "SourceVolume": "D:",
            },
        ]
        with self.assertRaisesRegex(ValueError, "D: target root"):
            manifest_apply.build_plan(rows, r"C:\resource\video\anime", None)
        plan = manifest_apply.build_plan(rows, r"C:\resource\video\anime", r"D:\AnimeView")
        self.assertEqual(
            plan[0]["target_path"],
            r"C:\resource\video\anime\2026年动画\A\Season 01\S01E01 - a.mkv",
        )
        self.assertEqual(
            plan[1]["target_path"],
            r"D:\AnimeView\2026年动画\B\Season 01\S01E01 - b.mkv",
        )

    def test_preflight_detects_conflict_before_writing_anything(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "view"
            root.mkdir()
            src1 = Path(td) / "a.mkv"
            src2 = Path(td) / "b.mkv"
            src1.write_bytes(b"a")
            src2.write_bytes(b"b")
            conflict = root / "b.mkv"
            conflict.write_bytes(b"other")
            plan = [
                {"source_path": str(src1), "target_path": str(root / "a.mkv")},
                {"source_path": str(src2), "target_path": str(conflict)},
            ]
            with self.assertRaisesRegex(ValueError, "conflict"):
                manifest_apply.preflight(plan)
            self.assertFalse((root / "a.mkv").exists())

    def test_apply_creates_hardlinks_and_rerun_reuses_them(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "source.mkv"
            src.write_bytes(b"video")
            target = Path(td) / "view" / "Show" / "S01E01 - source.mkv"
            plan = [{"source_path": str(src), "target_path": str(target)}]

            classified = manifest_apply.preflight(plan)
            self.assertEqual(classified[0]["state"], "MISSING")
            result = manifest_apply.apply_plan(classified)
            self.assertEqual(result["created"], 1)
            self.assertTrue(os.path.samefile(src, target))

            classified2 = manifest_apply.preflight(plan)
            self.assertEqual(classified2[0]["state"], "REUSABLE")
            result2 = manifest_apply.apply_plan(classified2)
            self.assertEqual(result2["created"], 0)
            self.assertEqual(result2["reused"], 1)


if __name__ == "__main__":
    unittest.main()

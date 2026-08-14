import csv
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "apply_jellyfin_full_canonical_view.py"
spec = importlib.util.spec_from_file_location("fcv_apply", SCRIPT)
fcv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fcv)


class FullCanonicalViewApplyTests(unittest.TestCase):
    def test_operation_policy(self):
        self.assertEqual(fcv.operation_for_path(r"D:\TV\a.mkv"), "HARDLINK")
        self.assertEqual(fcv.operation_for_path(r"D:\TV\a.ass"), "HARDLINK")
        self.assertEqual(fcv.operation_for_path(r"D:\TV\a.nfo"), "COPY")
        self.assertEqual(fcv.operation_for_path(r"D:\TV\poster.jpg"), "COPY")

    def test_apply_then_reuse(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "src"
            view = Path(td) / "view"
            temp = Path(td) / "temp"
            logs = Path(td) / "logs"
            src.mkdir()
            video = src / "video.mkv"
            nfo = src / "video.nfo"
            video.write_bytes(b"video-data")
            nfo.write_text(
                "<episodedetails><season>1</season><episode>2</episode></episodedetails>",
                encoding="utf-8",
            )
            plan = [
                {
                    "source_path": str(video),
                    "canonical_path": str(view / "TV" / "S01E02 - video.mkv"),
                    "library_name": "TV",
                    "role": "CORRECTION_VIDEO",
                    "operation": "HARDLINK",
                    "source_size": video.stat().st_size,
                    "expected_key": "S01E02",
                    "state": "MISSING",
                    "reason": "",
                },
                {
                    "source_path": str(nfo),
                    "canonical_path": str(view / "TV" / "S01E02 - video.nfo"),
                    "library_name": "TV",
                    "role": "CORRECTION_SIDECAR",
                    "operation": "COPY",
                    "source_size": nfo.stat().st_size,
                    "expected_key": "S01E02",
                    "state": "MISSING",
                    "reason": "",
                },
            ]
            manifest = str(logs / "full-manifest-v2.csv")
            result = fcv.apply_transaction(plan, str(view), str(temp), str(logs), manifest)
            self.assertEqual(result["created"], 2)
            self.assertTrue(os.path.samefile(video, view / "TV" / "S01E02 - video.mkv"))
            self.assertEqual((view / "TV" / "S01E02 - video.nfo").read_bytes(), nfo.read_bytes())
            self.assertTrue(Path(manifest).is_file())

            reusable, _ = fcv.preflight_plan(
                plan,
                str(view),
                str(logs / "missing-phase1.csv"),
                manifest,
                0,
            )
            self.assertEqual([row["state"] for row in reusable], ["REUSABLE", "REUSABLE"])

    def test_rollback_removes_only_created_destination(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "src"
            view = Path(td) / "view"
            temp = Path(td) / "temp"
            logs = Path(td) / "logs"
            src.mkdir()
            good = src / "good.mkv"
            good.write_bytes(b"good")
            missing = src / "missing.mkv"
            plan = [
                {
                    "source_path": str(good),
                    "canonical_path": str(view / "TV" / "good.mkv"),
                    "library_name": "TV",
                    "role": "PASSTHROUGH_VIDEO",
                    "operation": "HARDLINK",
                    "source_size": 4,
                    "expected_key": "",
                    "state": "MISSING",
                    "reason": "",
                },
                {
                    "source_path": str(missing),
                    "canonical_path": str(view / "TV" / "missing.mkv"),
                    "library_name": "TV",
                    "role": "PASSTHROUGH_VIDEO",
                    "operation": "HARDLINK",
                    "source_size": 4,
                    "expected_key": "",
                    "state": "MISSING",
                    "reason": "",
                },
            ]
            with self.assertRaises(FileNotFoundError):
                fcv.apply_transaction(
                    plan,
                    str(view),
                    str(temp),
                    str(logs),
                    str(logs / "full-manifest-v2.csv"),
                )
            self.assertTrue(good.exists())
            self.assertFalse((view / "TV" / "good.mkv").exists())
            self.assertFalse((view / "TV" / "missing.mkv").exists())

    def test_phase1_seed_owns_video_and_nfo(self):
        with tempfile.TemporaryDirectory() as td:
            manifest = Path(td) / "manifest.csv"
            with manifest.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["BuildId", "OriginalVideo", "CanonicalVideo", "OriginalNfo", "CanonicalNfo"],
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "BuildId": "old",
                        "OriginalVideo": r"D:\TV\ep.mkv",
                        "CanonicalVideo": r"D:\View\TV\S01E01 - ep.mkv",
                        "OriginalNfo": r"D:\TV\ep.nfo",
                        "CanonicalNfo": r"D:\View\TV\S01E01 - ep.nfo",
                    }
                )
            plan = [
                {
                    "source_path": r"D:\TV\ep.mkv",
                    "canonical_path": r"D:\View\TV\S01E01 - ep.mkv",
                    "library_name": "TV",
                    "role": "CORRECTION_VIDEO",
                    "operation": "HARDLINK",
                    "source_size": 1,
                    "expected_key": "S01E01",
                },
                {
                    "source_path": r"D:\TV\ep.nfo",
                    "canonical_path": r"D:\View\TV\S01E01 - ep.nfo",
                    "library_name": "TV",
                    "role": "CORRECTION_SIDECAR",
                    "operation": "COPY",
                    "source_size": 1,
                    "expected_key": "S01E01",
                },
            ]
            rows = fcv.phase1_seed_rows(str(manifest), plan, 1)
            self.assertEqual(len(rows), 2)
            self.assertEqual({row["Role"] for row in rows}, {"CORRECTION_VIDEO", "CORRECTION_SIDECAR"})

    def test_nfo_identity(self):
        with tempfile.TemporaryDirectory() as td:
            video = Path(td) / "ep.mkv"
            nfo = Path(td) / "ep.nfo"
            video.write_bytes(b"x")
            nfo.write_text(
                "<episodedetails><season>2</season><episode>9</episode></episodedetails>",
                encoding="utf-8",
            )
            fcv.validate_target_nfos([{"video_path": str(video), "season": 2, "episode": 9}])
            with self.assertRaises(ValueError):
                fcv.validate_target_nfos([{"video_path": str(video), "season": 2, "episode": 8}])


if __name__ == "__main__":
    unittest.main()

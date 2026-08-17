import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "create_hardlink.py"


def run_cli(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        text=True,
        capture_output=True,
    )


class CreateHardlinkCliTests(unittest.TestCase):
    def test_dry_run_does_not_create_target(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.mkv"
            target = root / "view" / "movie.mkv"
            source.write_bytes(b"video")

            result = run_cli(source, target)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("模式：试运行（未写入）", result.stdout)
            self.assertFalse(target.exists())

    def test_apply_creates_hardlink(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.mkv"
            target = root / "view" / "movie.mkv"
            source.write_bytes(b"video")

            result = run_cli(source, target, "--apply")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target.is_file())
            self.assertTrue(os.path.samefile(source, target))
            self.assertIn("状态：硬链接已创建。", result.stdout)

    def test_existing_same_hardlink_is_reusable(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.mkv"
            target = root / "view" / "movie.mkv"
            source.write_bytes(b"video")
            target.parent.mkdir()
            os.link(source, target)

            result = run_cli(source, target, "--apply")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("无需处理", result.stdout)
            self.assertTrue(os.path.samefile(source, target))

    def test_existing_different_target_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.mkv"
            target = root / "movie.mkv"
            source.write_bytes(b"video-a")
            target.write_bytes(b"video-b")

            result = run_cli(source, target, "--apply")

            self.assertEqual(result.returncode, 1)
            self.assertIn("目标路径已经存在且不是同一个硬链接", result.stderr)
            self.assertEqual(target.read_bytes(), b"video-b")

    def test_missing_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "missing.mkv"
            target = root / "movie.mkv"

            result = run_cli(source, target, "--apply")

            self.assertEqual(result.returncode, 1)
            self.assertIn("源文件不存在或不是普通文件", result.stderr)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()

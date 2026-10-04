import csv
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("analyze_anime_filenames", ROOT / "scripts" / "analyze_anime_filenames.py")
mod = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = mod
assert SPEC.loader is not None
SPEC.loader.exec_module(mod)


def parser():
    return mod.FilenameParser(ROOT / "rules")


def test_bracket_chain_tokuten():
    row = parser().parse_filename("[DBD-Raws][Clevatess][Tokuten 03][1080P][BDRip].mkv")
    assert row["ReleaseGroup"] == "DBD-Raws"
    assert row["TitleCandidate"] == "Clevatess"
    assert row["SpecialType"] == "TOKUTEN"
    assert row["SpecialNumber"] == "03"
    assert "1080P" in row["TechnicalTags"]
    assert "BDRIP" in row["TechnicalTags"]
    assert row["ParseStatus"] == "FULL"


def test_dash_episode_and_total_number_is_kept_as_is():
    row = parser().parse_filename("[DMG&LoliHouse] Spy x Family - 38 [WebRip 1080p].mkv")
    assert row["ReleaseGroup"] == "DMG&LoliHouse"
    assert row["TitleCandidate"] == "Spy x Family"
    assert row["RawEpisode"] == "38"
    assert row["ExplicitSeason"] == ""
    assert row["SpecialType"] == ""


def test_title_season_hint_and_version_are_field_children():
    row = parser().parse_filename("[Nekomoe kissaten] Medalist[S2][03v2][WebRip 1080p].mkv")
    assert row["TitleCandidate"] == "Medalist"
    assert row["ExplicitSeason"] == "2"
    assert row["RawEpisode"] == "03"
    assert row["Version"] == "2"


def test_explicit_sxxeyy():
    row = parser().parse_filename("[Nix-Raws] World Is Dancing S01E05 [1080p].mkv")
    assert row["TitleCandidate"] == "World Is Dancing"
    assert row["ExplicitSeason"] == "01"
    assert row["ExplicitEpisode"] == "05"


def test_spy_title_does_not_trigger_sp():
    row = parser().parse_filename("[DMG&LoliHouse] SPY x FAMILY - 38 [1080p].mkv")
    assert row["TitleCandidate"] == "SPY x FAMILY"
    assert row["RawEpisode"] == "38"
    assert row["SpecialType"] == ""


def test_ncop_ed_special():
    row = parser().parse_filename("[FLsnow][Star-Detective_Precure][NCOP_ED_01][1080p].mkv")
    assert row["SpecialType"] == "NCOP_ED"
    assert row["SpecialNumber"] == "01"


def test_directory_scan_outputs_csv_and_skips_non_video(tmp_path):
    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / "[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26 - 03 [WebRip 1080p].mkv").write_bytes(b"x")
    (nested / "subtitle.ass").write_text("x", encoding="utf-8")
    output = tmp_path / "out.csv"

    counts = mod.analyze_directory(tmp_path, output, ROOT / "rules")
    assert counts["TOTAL"] == 1
    with output.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 1
    assert rows[0]["TitleCandidate"] == "Fujimoto Tatsuki 17-26"
    assert rows[0]["RawEpisode"] == "03"


def test_numbered_episode_with_label():
    row = parser().parse_filename("[SomeGroup][Fate strange Fake][01 伪典的宣战][1080p].mkv")
    assert row["TitleCandidate"] == "Fate strange Fake"
    assert row["RawEpisode"] == "01"


def test_leading_zero_sp_marker():
    row = parser().parse_filename("[SomeGroup][Fate strange Fake][00&SP 黎明低语][1080p].mkv")
    assert row["SpecialType"] == "SP"

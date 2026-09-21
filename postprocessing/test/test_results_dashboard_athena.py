# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Pure-Python checks of the Athena adapter's helpers. No Athena."""

from comstockpostproc.results_dashboard import athena


def test_upgrade_literal_is_typed_to_the_column():
    assert athena.upgrade_literal(0, "bigint") == "0"
    assert athena.upgrade_literal(0, "integer") == "0"
    assert athena.upgrade_literal(0, "varchar") == "'0'"
    assert athena.upgrade_literal(0, "string") == "'0'"
    assert athena.upgrade_literal(0, None) == "0"


def test_invalidate_cache_drops_only_entries_that_read_the_run(tmp_path, monkeypatch):
    monkeypatch.setattr(athena, "CACHE_DIR", tmp_path)
    (tmp_path / "a.sql").write_text("SELECT 1 FROM myrun_md_agg_national_by_state_parquet", encoding="utf-8")
    (tmp_path / "a.parquet").write_bytes(b"x")
    (tmp_path / "b.sql").write_text("SELECT 1 FROM other_md_agg_national_by_state_parquet", encoding="utf-8")
    (tmp_path / "b.parquet").write_bytes(b"x")
    (tmp_path / "legacy.parquet").write_bytes(b"x")       # no sidecar: left alone
    assert athena.invalidate_cache("myrun") == 1
    assert not (tmp_path / "a.parquet").exists() and not (tmp_path / "a.sql").exists()
    assert (tmp_path / "b.parquet").exists() and (tmp_path / "legacy.parquet").exists()


def test_invalidate_cache_without_a_cache_dir_is_a_noop(tmp_path, monkeypatch):
    monkeypatch.setattr(athena, "CACHE_DIR", tmp_path / "absent")
    assert athena.invalidate_cache("myrun") == 0

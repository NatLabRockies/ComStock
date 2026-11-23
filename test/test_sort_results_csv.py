import importlib.util
from pathlib import Path

import pytest


SCRIPT = Path(__file__).parents[1] / '.github' / 'scripts' / 'sort_results_csv.py'
SPEC = importlib.util.spec_from_file_location('sort_results_csv', SCRIPT)
SORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SORTER)


def sort_text(tmp_path, text, keys=SORTER.DEFAULT_KEYS):
    source = tmp_path / 'source.csv'
    destination = tmp_path / 'sorted.csv'
    source.write_bytes(text.encode('utf-8'))
    SORTER.sort_results_csv(source, destination, keys)
    return destination.read_bytes().decode('utf-8')


def test_sorts_numerically_by_building_then_state_and_keeps_record_text(tmp_path):
    text = (
        'bldg_id,in.state,note\n'
        '10,OH,""\n'
        '2,OH,"multi\nline"\n'
        '2,IN,1.50\n'
    )
    assert sort_text(tmp_path, text) == (
        'bldg_id,in.state,note\n'
        '2,IN,1.50\n'
        '2,OH,"multi\nline"\n'
        '10,OH,""\n'
    )


def test_adds_newline_when_last_record_moves(tmp_path):
    assert sort_text(tmp_path, 'bldg_id,in.state\n2,IN\n1,IN') == 'bldg_id,in.state\n1,IN\n2,IN\n'


def test_keeps_crlf_line_endings(tmp_path):
    assert sort_text(tmp_path, 'bldg_id,in.state\r\n2,IN\r\n1,IN\r\n') == 'bldg_id,in.state\r\n1,IN\r\n2,IN\r\n'


@pytest.mark.parametrize(('text', 'message'), [
    ('bldg_id,other\n1,IN\n', 'missing sort columns: in.state'),
    ('bldg_id,in.state\n1,IN\n1,IN\n', 'duplicate records'),
    ('bldg_id,in.state\n1,IN,extra\n', 'record 2 has 3 fields'),
])
def test_rejects_invalid_results(tmp_path, text, message):
    with pytest.raises(ValueError, match=message):
        sort_text(tmp_path, text)

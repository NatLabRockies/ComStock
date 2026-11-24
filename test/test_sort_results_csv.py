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


def sort_with_previous(tmp_path, new_text, previous_text, **tolerances):
    source = tmp_path / 'source.csv'
    previous = tmp_path / 'previous.csv'
    source.write_bytes(new_text.encode('utf-8'))
    previous.write_bytes(previous_text.encode('utf-8'))
    summary = SORTER.sort_results_csv(source, previous, SORTER.DEFAULT_KEYS, previous=previous, **tolerances)
    return previous.read_bytes().decode('utf-8'), summary


def test_keeps_previous_text_for_values_within_tolerance(tmp_path):
    previous = 'bldg_id,in.state,energy,note\n1,IN,6297.802526454677,""\n'
    new = 'bldg_id,in.state,energy,note\n1,IN,6297.802526454675,""\n'
    text, summary = sort_with_previous(tmp_path, new, previous)
    assert text == previous
    assert summary['kept_within_tolerance'] == 1
    assert not summary['changed']


def test_takes_new_values_beyond_tolerance_and_keeps_others(tmp_path):
    previous = 'bldg_id,in.state,site,savings,label\n1,IN,98133.33333333333,-38.888888888890506,a\n'
    new = 'bldg_id,in.state,site,savings,label\n1,IN,98133.33333333334,-47.222222222226264,b\n'
    text, summary = sort_with_previous(tmp_path, new, previous)
    assert text == 'bldg_id,in.state,site,savings,label\n1,IN,98133.33333333333,-47.222222222226264,b\n'
    assert summary['changed'] == {'savings': 1, 'label': 1}


def test_detects_change_just_above_tolerance(tmp_path):
    previous = 'bldg_id,in.state,value\n1,IN,1.000000000\n'
    new = 'bldg_id,in.state,value\n1,IN,1.000000002\n'
    text, summary = sort_with_previous(tmp_path, new, previous, rel_tol=1e-9)
    assert text == new
    assert summary['changed'] == {'value': 1}


def test_matches_rows_by_key_and_columns_by_name(tmp_path):
    previous = 'bldg_id,in.state,b,a\n2,IN,2.0000000000001,x\n1,IN,1.0000000000001,y\n'
    new = 'bldg_id,in.state,a,b,c\n1,IN,y,1.0,new\n3,IN,z,3.0,new\n2,IN,x,2.0,new\n'
    text, summary = sort_with_previous(tmp_path, new, previous)
    assert text == (
        'bldg_id,in.state,a,b,c\n'
        '1,IN,y,1.0000000000001,new\n'
        '2,IN,x,2.0000000000001,new\n'
        '3,IN,z,3.0,new\n'
    )
    assert summary['new_records'] == 1


def test_never_treats_nan_or_text_as_within_tolerance(tmp_path):
    previous = 'bldg_id,in.state,x,y\n1,IN,NaN,1.0\n'
    new = 'bldg_id,in.state,x,y\n1,IN,1.0,NaN\n'
    text, summary = sort_with_previous(tmp_path, new, previous)
    assert text == new
    assert summary['changed'] == {'x': 1, 'y': 1}


def test_missing_previous_file_only_sorts(tmp_path):
    source = tmp_path / 'source.csv'
    destination = tmp_path / 'sorted.csv'
    source.write_bytes(b'bldg_id,in.state\n2,IN\n1,IN\n')
    SORTER.sort_results_csv(source, destination, SORTER.DEFAULT_KEYS, previous=tmp_path / 'absent.csv')
    assert destination.read_bytes() == b'bldg_id,in.state\n1,IN\n2,IN\n'


@pytest.mark.parametrize(('text', 'message'), [
    ('bldg_id,other\n1,IN\n', 'missing sort columns: in.state'),
    ('bldg_id,in.state\n1,IN\n1,IN\n', 'duplicate records'),
    ('bldg_id,in.state\n1,IN,extra\n', 'record 2 has 3 fields'),
])
def test_rejects_invalid_results(tmp_path, text, message):
    with pytest.raises(ValueError, match=message):
        sort_text(tmp_path, text)

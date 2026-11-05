# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""ComStock.cast_columns_to_definitions: every exported column gets the type in the column definitions,
and only conversions that keep every value are made."""

import logging

import polars as pl
import pytest

from comstockpostproc import comstock as cs
from comstockpostproc.comstock import ComStock

HEADER = 'location,original_col_name,new_col_name,full_metadata,basic_metadata,data_type,original_units,new_units,field_description'
TEST_DEFINITIONS = [  # (new_col_name, data_type, units)
    ('int_to_float', 'float', ''),
    ('text_to_float', 'float', ''),
    ('categorical_to_text', 'string', ''),
    ('null_to_float', 'float', ''),
    ('float_to_int', 'integer', ''),
    ('float_to_text', 'string', ''),
    ('int_to_text', 'string', ''),
    ('bool_to_float', 'float', ''),
    ('bool_to_text', 'string', ''),
    ('text_to_bool', 'boolean', ''),
    ('out.energy', 'float', 'kwh'),
]


@pytest.fixture
def cast(tmp_path, monkeypatch):
    """cast_columns_to_definitions on a ComStock made without __init__, reading a small definitions file."""
    lines = [HEADER] + [f'results.csv,raw.{name},{name},TRUE,FALSE,{dtype},{units},{units},test column'
                        for name, dtype, units in TEST_DEFINITIONS]
    (tmp_path / cs.COLUMN_DEFINITION_FILE_NAME).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    monkeypatch.setattr(cs, 'RESOURCE_DIR', str(tmp_path))
    comstock = ComStock.__new__(ComStock)
    return lambda df: comstock.cast_columns_to_definitions(df.lazy())


def test_lossless_casts_are_made_and_keep_every_value(cast, caplog):
    df = pl.DataFrame({
        'int_to_float': [1, 2],
        'text_to_float': ['1.5', '2'],
        'categorical_to_text': pl.Series(['a', 'b'], dtype=pl.Categorical),
        'null_to_float': pl.Series([None, None], dtype=pl.Null),
        'out.energy..kwh': [3, 4],  # matched to its definition without the units suffix
        'undefined': [5, 6],  # no definition: left as it is
    })
    with caplog.at_level(logging.INFO):
        out = cast(df).collect()
    assert out.schema == pl.Schema({'int_to_float': pl.Float64, 'text_to_float': pl.Float64, 'categorical_to_text': pl.String,
                                    'null_to_float': pl.Float64, 'out.energy..kwh': pl.Float64, 'undefined': pl.Int64})
    assert out['int_to_float'].to_list() == [1.0, 2.0]
    assert out['text_to_float'].to_list() == [1.5, 2.0]
    assert out['categorical_to_text'].to_list() == ['a', 'b']
    assert out['null_to_float'].to_list() == [None, None]
    assert out['out.energy..kwh'].to_list() == [3.0, 4.0]
    assert 'Casting 5 exported columns' in caplog.text
    assert '2 Int64 to Float64' in caplog.text  # the log line counts each kind of conversion


def test_float_to_integer_keeps_whole_numbers(cast):
    out = cast(pl.DataFrame({'float_to_int': [1.0, 2.0, None]})).collect()
    assert out.schema['float_to_int'] == pl.Int64
    assert out['float_to_int'].to_list() == [1, 2, None]


def test_float_with_decimals_fails_instead_of_being_truncated(cast):
    # The reason for the guard: polars drops the decimals even in a strict cast
    assert pl.Series([2.5]).cast(pl.Int64, strict=True).to_list() == [2]
    lf = cast(pl.DataFrame({'float_to_int': [1.0, 2.5]}))
    with pytest.raises(pl.exceptions.InvalidOperationError, match='float_to_int'):
        lf.collect()


@pytest.mark.parametrize('column, values', [
    ('float_to_text', [2.0]),  # would be written as '2.0'
    ('int_to_text', [1001]),  # an ID would lose any leading zero
    ('bool_to_text', [True]),
    ('bool_to_float', [True]),
])
def test_values_that_would_change_are_refused(cast, column, values):
    with pytest.raises(TypeError, match=column):
        cast(pl.DataFrame({column: values}))


def test_every_refused_column_is_named_at_once(cast):
    with pytest.raises(TypeError) as err:
        cast(pl.DataFrame({'float_to_text': [2.0], 'int_to_text': [7], 'int_to_float': [1]}))
    assert 'float_to_text' in str(err.value) and 'int_to_text' in str(err.value)
    assert 'int_to_float' not in str(err.value)


def test_text_that_is_not_a_number_fails_instead_of_becoming_null(cast):
    lf = cast(pl.DataFrame({'text_to_float': ['1', 'NA']}))
    with pytest.raises(pl.exceptions.InvalidOperationError):
        lf.collect()


def test_columns_defined_as_boolean_are_left_as_they_are(cast, caplog):
    with caplog.at_level(logging.WARNING):
        out = cast(pl.DataFrame({'text_to_bool': ['True', 'False']})).collect()
    assert out.schema['text_to_bool'] == pl.String
    assert 'Not casting text_to_bool' in caplog.text


def test_every_exported_definition_has_a_type_the_cast_knows():
    # A blank or misspelt data_type would make the cast skip that column without a word
    col_defs = pl.read_csv(f'{cs.RESOURCE_DIR}/{cs.COLUMN_DEFINITION_FILE_NAME}', infer_schema_length=0)
    exported = col_defs.filter(pl.col('full_metadata') == 'TRUE')
    unknown = exported.filter(~pl.col('data_type').is_in(['float', 'integer', 'string', 'boolean']) | pl.col('data_type').is_null())
    assert unknown.height == 0, unknown.select('new_col_name', 'data_type').rows()

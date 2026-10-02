# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Site EUI savings distributions plot kBtu/ft2, the units on their axes. No data, no S3.

The savings intensity columns are ..kwh_per_ft2. write_image is stubbed out, so kaleido never
runs: each figure is kept under the file name it would have been written to.
"""

import os

import numpy as np
import pandas as pd
import plotly.graph_objects as go
import pytest

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.plotting_mixin import PlottingMixin
from comstockpostproc.units_mixin import UnitsMixin

KWH_TO_KBTU = 3.412141633


class Plotter(NamingMixin, UnitsMixin, PlottingMixin):
    image_type = 'jpg'


P = Plotter()
KWH_PER_FT2 = [0.5, -1.0, 2.0]   # the upgrade rows of every EUI savings column
PCT_SAVINGS = [10.0, -5.0, 40.0]  # the upgrade rows of every percent savings column


def _eui(c):
    return P.col_name_to_savings(P.col_name_to_eui(c))


def _frame():
    """One baseline row and three upgrade rows of every savings column the four plots read."""
    data = {P.UPGRADE_ID: [0, 1, 1, 1], P.UPGRADE_NAME: 'Test Measure',
            P.BLDG_TYPE: 'Office', P.CZ_ASHRAE: '4A', P.HVAC_SYS: 'PSZ-AC'}
    for c in P.COLS_ENDUSE_ANN_ENGY + P.COLS_TOT_ANN_ENGY:
        data[_eui(c)] = [99.0] + KWH_PER_FT2
        data[P.col_name_to_percent_savings(c, 'percent')] = [99.0] + PCT_SAVINGS
    return pd.DataFrame(data)


def test_eui_columns_convert_from_kwh_to_kbtu_per_ft2():
    col = _eui(P.ANN_TOT_ENGY_KBTU)
    assert col == 'out.site_energy.total.energy_savings_intensity..kwh_per_ft2'
    df = pd.DataFrame({col: [1.0, -2.0, 0.0, np.nan], 'other': [1.0, 2.0, 3.0, 4.0]})

    out = P.convert_eui_cols_to_kbtu_per_ft2(df, [col, col])  # listed twice, converted once

    assert out[col].tolist()[:3] == pytest.approx([KWH_TO_KBTU, -2 * KWH_TO_KBTU, 0.0])
    assert np.isnan(out[col].iloc[3])
    assert out['other'].tolist() == [1.0, 2.0, 3.0, 4.0]
    assert df[col].tolist()[:3] == [1.0, -2.0, 0.0]  # the caller's frame is left alone


@pytest.mark.parametrize('method, groupings', [
    ('plot_measure_savings_distributions_enduse_and_fuel', ['end_use', 'fuel']),
    ('plot_measure_savings_distributions_by_building_type', ['building_type']),
    ('plot_measure_savings_distributions_by_climate_zone', ['climate_zone']),
    ('plot_measure_savings_distributions_by_hvac_system_type', ['hvac_system']),
])
def test_site_eui_savings_figures_plot_the_kbtu_per_ft2_on_their_axes(method, groupings, tmp_path, monkeypatch):
    written = {}

    def keep(fig, path, **kwargs):
        written[os.path.basename(path)] = fig

    monkeypatch.setattr(go.Figure, 'write_image', keep)

    getattr(P, method)(df=_frame(), output_dir=str(tmp_path))

    # file names are unchanged
    assert set(written) == ({f'site_eui_savings_by_{g}.jpg' for g in groupings}
                            | {f'percent_site_energy_savings_by_{g}.jpg' for g in groupings})
    for g in groupings:
        eui_fig = written[f'site_eui_savings_by_{g}.jpg']
        assert eui_fig.layout.xaxis.title.text.endswith('(kBtu/ft<sup>2</sup>)')
        for trace in eui_fig.data:
            assert np.asarray(trace.x, dtype=float).tolist() == pytest.approx([v * KWH_TO_KBTU for v in KWH_PER_FT2])
        # percent savings are not converted
        for trace in written[f'percent_site_energy_savings_by_{g}.jpg'].data:
            assert np.asarray(trace.x, dtype=float).tolist() == pytest.approx(PCT_SAVINGS)

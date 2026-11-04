# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# This class is a utility class to select the columns need to be plotted in plotting_mixin
# and convert the lazy frame to pandas dataframe to plotting_mixin
import polars as pl
import pandas as pd
from typing import Callable
from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
import logging
logger = logging.getLogger(__name__)


class LazyFramePlotter(NamingMixin):

    def __init__(self):

        # Every ploting method need these columns
        self.BASE_COLUMNS = ["applicability", self.UPGRADE_NAME, self.BLDG_ID]

        self.WTD_COLUMNS_ANN_ENDUSE = [self.col_name_to_weighted(
            col_name=c, new_units=UnitsMixin.UNIT.ENERGY.TBTU) for c in self.COLS_ENDUSE_ANN_ENGY]

        self.WTD_COLS_GROCERY_REFRIG_DETAIL = [self.col_name_to_weighted(
            col_name=c, new_units=UnitsMixin.UNIT.ENERGY.TBTU) for c in self.COLS_GROCERY_REFRIG_DEFROST_ENDUSE]

        self.WTD_COLUMNS_ANN_PV = [self.col_name_to_weighted(
            col_name=c, new_units=UnitsMixin.UNIT.ENERGY.TBTU) for c in self.COLS_GEN_ANN_ENGY]

        self.WTD_GHG_COLUMNS = [self.col_name_to_weighted(
            c, UnitsMixin.UNIT.MASS.CO2E_MMT) for c in self.GHG_FUEL_COLS]

        self.UTILITY_COLUMNS = self.COLS_UTIL_BILLS + \
            ['out.utility_bills.electricity_bill_max..usd',
             'out.utility_bills.electricity_bill_min..usd']
        self.WTD_UTILITY_COLUMNS = [self.col_name_to_weighted(
            c, UnitsMixin.UNIT.CURRENCY.BILLION_USD) for c in self.UTILITY_COLUMNS]

        #plot_floor_area_and_energy_totals columns
        self.WTD_COLUMNS_SUMMARIZE = [self.col_name_to_weighted(col_name=c, new_units=UnitsMixin.UNIT.ENERGY.TBTU) for c in [
            self.ANN_TOT_ENGY_KBTU, self.ANN_TOT_ELEC_KBTU, self.ANN_TOT_GAS_KBTU]]

        self.WTD_COLUMNS_SUMMARIZE += [self.col_name_to_weighted(col_name=self.FLR_AREA),
                                    self.CEN_DIV, self.BLDG_TYPE, self.VINTAGE]

        #plot_eui_boxplots columns
        self.EUI_ANN_TOTL_COLUMNS = list(map(self.col_name_to_eui, [
            self.ANN_TOT_ENGY_KBTU, self.ANN_TOT_ELEC_KBTU, self.ANN_TOT_GAS_KBTU]))
        self.EUI_ANN_TOTL_COLUMNS += [self.col_name_to_weighted(self.FLR_AREA)]

        self.SAVINGS_DISTRI_ENDUSE_COLUMNS = [self.col_name_to_savings(self.col_name_to_eui(
            c)) for c in self.COLS_ENDUSE_ANN_ENGY + self.COLS_TOT_ANN_ENGY]
        self.SAVINGS_DISTRI_ENDUSE_COLUMNS += [self.col_name_to_percent_savings(
            c, UnitsMixin.UNIT.DIMLESS.PERCENT) for c in self.COLS_ENDUSE_ANN_ENGY + self.COLS_TOT_ANN_ENGY]

        self.EUI_SAVINGS_COLUMNS = [self.col_name_to_savings(self.col_name_to_area_intensity(c)) for c in [self.UTIL_BILL_TOTAL_MEAN] + self.COLS_UTIL_BILLS]
        self.EUI_SAVINGS_COLUMNS += [self.col_name_to_percent_savings(self.col_name_to_weighted(c), UnitsMixin.UNIT.DIMLESS.PERCENT) for c in [self.UTIL_BILL_TOTAL_MEAN] + self.COLS_UTIL_BILLS]

        self.SAVINGS_DISTRI_BUILDINTYPE = [self.col_name_to_savings(self.col_name_to_eui(self.ANN_TOT_ENGY_KBTU)),
                                           self.col_name_to_percent_savings(self.ANN_TOT_ENGY_KBTU, UnitsMixin.UNIT.DIMLESS.PERCENT)]

        self.QOI_COLUMNS = list(set(self.QOI_MAX_DAILY_TIMING_COLS
                                    + self.QOI_MAX_USE_COLS_NORMALIZED + self.QOI_MIN_USE_COLS_NORMALIZED))

        #plot_energy_rate_boxplots columns
        self.SUMMARIZE_COLUMNS = [self.col_name_to_energy_rate(c) for c in [self.UTIL_BILL_ELEC, self.UTIL_BILL_GAS]]

        # plot unmet hours
        self.UNMET_HOURS_COLS = list(set(self.UNMET_HOURS_COLS))

    @staticmethod
    def select_columns(
        lazy_frame: pl.LazyFrame,
        columns: list[str],
        *,
        include_replicate_weights: bool = False,
        include_base_weight: bool = True,
    ) -> pd.DataFrame:
        # start from requested columns
        cols = list(set(columns))

        # optionally include base weight
        if include_base_weight and NamingMixin.BLDG_WEIGHT in lazy_frame.collect_schema().names():
            if NamingMixin.BLDG_WEIGHT not in cols:
                cols.append(NamingMixin.BLDG_WEIGHT)

        # optionally include all replicate weights
        if include_replicate_weights:
            rep_cols = NamingMixin.list_replicate_weight_cols(lazy_frame)
            cols = list(set(cols + rep_cols))

        # sanity check
        NamingMixin.ensure_weight_columns_present(
            cols,
            require_base=include_base_weight,
            require_reps=include_replicate_weights,
        )

        missing_columns = [c for c in cols if c not in lazy_frame.collect_schema().names()]
        assert not missing_columns, f"Columns {missing_columns} not in lazy_frame columns"

        # collect
        time_start = pd.Timestamp.now()
        pandas_df = lazy_frame.clone().select(cols).collect().to_pandas()
        time_end = pd.Timestamp.now()
        logger.info(
            f"Collecting dataframe and converting to Pandas for plotting took {time_end - time_start}. "
            f"Dataframe shape: {pandas_df.shape}"
        )

        # cast types (centralized via mixin)
        cast_map = NamingMixin.build_cast_map_for_plotting(cols)
        failed = []
        for col, dtype in cast_map.items():
            try:
                pandas_df = pandas_df.astype({col: dtype})
            except Exception as e:
                failed.append((col, dtype, str(e)))
        if failed:
            raise Exception(
                f"Type casting failures: {failed}\n"
                f"Polars schema: {lazy_frame.select(cols).schema}\n"
                f"Pandas dtypes: {pandas_df.dtypes}"
            )
        return pandas_df

    @staticmethod
    def plot_with_lazy(
        plot_method: Callable,
        lazy_frame: pl.LazyFrame,
        columns: list[str],
        *args,
        include_replicate_weights: bool = False,   # default off as most plots don't include CBECs TODO update all plots to have this call currently only CBECs plots have these calls as true
        include_base_weight: bool = True,   # default on to include base weights for most plots
        **kwargs
    ):
        df: pd.DataFrame = LazyFramePlotter.select_columns(
            lazy_frame,
            columns,
            include_replicate_weights=include_replicate_weights,
            include_base_weight=include_base_weight,
        )

        def inner(*args2, **kwargs2):
            time_start = pd.Timestamp.now()
            kwargs2.update(kwargs)
            kwargs2["df"] = df
            assert df is not None, "df is None"
            result = plot_method(*args2, **kwargs2)
            # Plot methods queue their figures rather than writing them one at a time,
            # so export whatever this method produced before moving on. Flushing here
            # keeps every plot method batched without each one having to remember.
            owner = getattr(plot_method, "__self__", None)
            if owner is not None and hasattr(owner, "flush_figures"):
                owner.flush_figures()
            logger.info(f"{plot_method.__name__} took {pd.Timestamp.now() - time_start} to plot.")
            return result

        return inner
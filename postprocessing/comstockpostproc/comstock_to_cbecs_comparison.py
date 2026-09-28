# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
import os

import logging
import numpy as np
import pandas as pd
import polars as pl
from typing import List

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.plotting_mixin import PlottingMixin
from comstockpostproc.cbecs import CBECS
from comstockpostproc.comstock import ComStock

from comstockpostproc.lazyframeplotter import LazyFramePlotter

logger = logging.getLogger(__name__)

class ComStockToCBECSComparison(NamingMixin, UnitsMixin, PlottingMixin):
    def __init__(self, comstock_list: List[ComStock], cbecs_list: List[CBECS], upgrade_id=0, image_type='jpg', name=None, make_comparison_plots=True, make_hvac_plots = False, building_type: str | None = None):
        """
        Creates the ComStock to CBECS comaprison plots.

        Args:
            comstock_list (List[ComStock]): List of ComStock dataset objects.
            cbecs_list (List[CBECS]): List of CBECS dataset objects.
            upgrade_id (Union(str, int), optional): The upgrade ID to include in the plots, or 'All' to include all upgrades for the ComStock run(s).
            image_type (str, optional): Image file type to use. Defaults to 'jpg'.
            name (str, optional): Name of output directory. If None, a name will be generated. Defaults to None.
            make_comparison_plots (bool, optional): Flag to create compairison plots. Defaults to True.
            building_type (str | None, optional): ComStock building type to filter plots to.
                Valid values: 'FullServiceRestaurant', 'QuickServiceRestaurant', 'RetailStripmall',
                'RetailStandalone', 'SmallOffice', 'MediumOffice', 'LargeOffice', 'PrimarySchool',
                'SecondarySchool', 'Outpatient', 'Hospital', 'SmallHotel', 'LargeHotel', 'Warehouse',
                'Grocery'. If None, all building types are plotted.
        """
        # Initialize members
        self.comstock_list = comstock_list
        self.cbecs_list = cbecs_list
        self.data = None
        self.color_map = {}
        self.image_type = image_type
        self.name = name
        self.column_for_grouping = self.DATASET
        self.lazyframe_plotter: LazyFramePlotter = LazyFramePlotter()

        # Optional building type filter for faster plotting.
        requested_building_type = self._validate_building_type(building_type)

        # Concatenate the datasets and create a color map
        dfs_to_concat = []
        comstock_dfs_to_concat = []
        dataset_names = []
        comstock_color_map = {}
        for dataset in (cbecs_list + comstock_list):
            # remove measure data from ComStock
            if isinstance(dataset, ComStock): #dataset is ComStock
                assert isinstance(dataset.data, pl.LazyFrame)
                # Instantiate the plotting data lazyframe if it doesn't yet exist:
                if not isinstance(dataset.plotting_data, pl.LazyFrame):
                    logger.info(f'Instantiating plotting lazyframe for comstock dataset {dataset.dataset_name}.')
                    dataset.create_plotting_lazyframe()
                assert isinstance(dataset.plotting_data, pl.LazyFrame)

                up_id_name: list = dataset.plotting_data.select(dataset.UPGRADE_ID, dataset.UPGRADE_NAME).collect().unique().to_numpy().tolist()
                up_name_map = {k: v for k, v in up_id_name}
                valid_upgrade_id = [x for x in up_name_map.keys()]
                valid_upgrade_name = [up_name_map[x] for x in valid_upgrade_id]

                logger.info(f"Valid upgrades for {dataset.dataset_name}: {valid_upgrade_id} with names {up_name_map}")
                if upgrade_id == 'All':
                    # df_data: pl.LazyFrame = dataset.data
                    # df_data[dataset.DATASET] = df_data[dataset.DATASET] + ' - ' + df_data['upgrade_name']
                    comstock_dfs_to_concat.append(dataset.plotting_data)
                    # df_data[dataset.DATASET] = df_data[dataset.DATASET].astype(str) + ' - ' + df_data[dataset.UPGRADE_NAME].astype(str)
                    dataset.plotting_data = dataset.plotting_data.with_columns((
                        pl.col(dataset.DATASET).cast(pl.Utf8) + ' - ' + pl.col(dataset.UPGRADE_NAME).cast(pl.Utf8)
                    ).alias(dataset.DATASET))
                    dfs_to_concat.append(dataset.plotting_data)
                    # up_name_map = dict(zip(df_data[dataset.UPGRADE_ID].unique(), df_data[dataset.UPGRADE_NAME].unique()))
                    # upgrade_list = list(df_data[dataset.UPGRADE_ID].unique())
                    color_dict = self.linear_gradient(dataset.COLOR_COMSTOCK_BEFORE, dataset.COLOR_COMSTOCK_AFTER, len(valid_upgrade_id))
                    for idx, upgrade_id in enumerate(valid_upgrade_id):
                        dataset_name = dataset.dataset_name + ' - ' + up_name_map[upgrade_id]
                        dataset_names.append(dataset_name)
                        comstock_color_map[dataset_name] = color_dict['hex'][idx]
                        self.color_map[dataset_name] = color_dict['hex'][idx]

                elif upgrade_id not in valid_upgrade_id:
                    logger.error(f"Upgrade {upgrade_id} not found in {dataset.dataset_name}. Enter a valid upgrade ID in the ComStockToCBECSComparison constructor or \"All\" to include all upgrades.")
                else:
                    df_data = dataset.plotting_data.filter(pl.col(dataset.UPGRADE_ID) == upgrade_id)
                    df_data = df_data.with_columns((pl.col(dataset.DATASET).cast(pl.Utf8) + ' - ' + pl.col(dataset.UPGRADE_NAME).cast(pl.Utf8)).alias(dataset.DATASET))
                    dataset_name = dataset.dataset_name + " - " + up_name_map[upgrade_id]
                    comstock_dfs_to_concat.append(df_data)
                    dfs_to_concat.append(df_data)
                    comstock_color_map[dataset_name] = dataset.color
                    self.color_map[dataset_name] = dataset.color
                    dataset_names.append(dataset_name)
            else: #dataset is CBECS
                assert isinstance(dataset.data, pl.LazyFrame)
                df_data = dataset.data
                dfs_to_concat.append(df_data)
                self.color_map[dataset.dataset_name] = dataset.color
                dataset_names.append(dataset.dataset_name)

        # Name the comparison
        if self.name is None:
            if len(dataset_names) > 2:
                self.name = ' vs '.join(sorted(dataset_names, key=len)[:2]) + ' and Upgrades'
            else:
                self.name = ' vs '.join(sorted(dataset_names))

        # Combine into a single dataframe for convenience
        # self.data = pd.concat(dfs_to_concat, join='inner', ignore_index=True)

        # Preserve optional grocery refrigeration detail columns in mixed CBECS/ComStock comparisons
        # by adding zero-filled placeholders where they are missing before schema intersection.
        optional_enduse_cols = list(self.lazyframe_plotter.WTD_COLS_GROCERY_REFRIG_DETAIL)
        dfs_with_optional_cols = []
        for df in dfs_to_concat:
            missing_optional_cols = [c for c in optional_enduse_cols if c not in df.collect_schema().names()]
            if missing_optional_cols:
                df = df.with_columns([pl.lit(0.0).alias(c) for c in missing_optional_cols])
            dfs_with_optional_cols.append(df)
        dfs_to_concat = dfs_with_optional_cols

        # There is no such a join='inner' in polars.concat, implement it manually
        common_columns = set(dfs_to_concat[0].collect_schema().names())
        for df in dfs_to_concat:
            common_columns = common_columns.intersection(set(df.collect_schema().names()))
        dfs_to_concat = [df.select(common_columns) for df in dfs_to_concat]
        self.data: pl.LazyFrame = pl.concat(dfs_to_concat, how="vertical_relaxed")
        if requested_building_type is not None:
            self.data = self._filter_to_building_type(self.data, requested_building_type)
        # Add Replicate Weights (CBECS only) for RSE calculations
        cbecs_src = cbecs_list[0]
        rep_cols = [self.BLDG_ID] + self.list_replicate_weight_cols(cbecs_src.data)

        weights_lf = cbecs_src.data.select(rep_cols)
        # Only join weights for CBECS rows; set others to NaN
        cbecs_dataset_name = f"CBECS {cbecs_src.year}"
        # Add a flag column to self.data to identify CBECS rows
        self.data = self.data.with_columns(
            (pl.col(self.DATASET) == cbecs_dataset_name).alias("is_cbecs")
        )
        # Join weights only for CBECS rows
        joined = self.data.join(weights_lf, on=self.BLDG_ID, how="left")
        # For non-CBECS rows, set replicate weights to None
        for col in rep_cols:
            joined = joined.with_columns(
                pl.when(pl.col("is_cbecs")).then(pl.col(col)).otherwise(None).alias(col)
            )
        self.data = joined.drop("is_cbecs")
        current_dir = os.path.dirname(os.path.abspath(__file__))

        # Combine just comstock runs into single dataframe for QOI plots
        common_columns = set(comstock_dfs_to_concat[0].collect_schema().names())
        all_columns = common_columns
        for df in comstock_dfs_to_concat:
            common_columns = common_columns & set(df.collect_schema().names())
        logger.info(f"Not including columns {all_columns - common_columns} in comstock only plots")
        comstock_dfs_to_concat = [df.select(common_columns) for df in comstock_dfs_to_concat]
        comstock_qoi_columns = [self.DATASET] + self.QOI_MAX_DAILY_TIMING_COLS + self.QOI_MAX_USE_COLS + self.QOI_MIN_USE_COLS + self.QOI_MAX_USE_COLS_NORMALIZED + self.QOI_MIN_USE_COLS_NORMALIZED
        comstock_all_df: pl.LazyFrame = pl.concat(comstock_dfs_to_concat, how="vertical_relaxed")
        if requested_building_type is not None:
            comstock_all_df = self._filter_to_building_type(comstock_all_df, requested_building_type)
        comstock_df: pl.LazyFrame = comstock_all_df.select(comstock_qoi_columns)
        comstock_enduse_columns = [self.DATASET] + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE + self.lazyframe_plotter.WTD_COLUMNS_ANN_PV + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE
        comstock_enduse_df: pl.LazyFrame = comstock_all_df.select(comstock_enduse_columns)

        # Make directories
        self.output_dir = os.path.join(current_dir, '..', 'output', self.name)
        for p in [self.output_dir]:
            if not os.path.exists(p):
                os.makedirs(p)

        #logger.info(f"type of self.data columns: {self.data.collect_schema().names(), self.data.dtypes, len(self.data.collect_schema().names()), len(self.data.dtypes)}")
        #logger.info(f"type of comstock_df columns: {comstock_df.collect_schema().names(), comstock_df.dtypes}")

        assert isinstance(self.data, pl.LazyFrame)
        assert isinstance(comstock_df, pl.LazyFrame)
        # self.data: pd.DataFrame = self.data.collect().to_pandas()
        # comstock_df: pd.DataFrame = comstock_df.collect().to_pandas()
        # assert isinstance(self.data, pd.DataFrame)
        # assert isinstance(comstock_df, pd.DataFrame)

        # Make ComStock to CBECS comparison plots
        if make_comparison_plots:
            self.make_plots(self.data, self.column_for_grouping, self.color_map, self.output_dir, make_hvac_plots)
            # Enduse and QOI plots can only be made with comstock data because CBECS data do not have QOI columns TODO fix these plots to work currently do not.
            self.make_enduse_plots(comstock_enduse_df, self.column_for_grouping, comstock_color_map, self.output_dir)
            # self.make_qoi_plots(comstock_df, self.column_for_grouping, comstock_color_map, self.output_dir)

        else:
            logger.info("make_comparison_plots is set to false, so not plots were created. Set make_comparison_plots to True for plots.")

    def make_plots(self, lazy_frame: pl.LazyFrame, column_for_grouping, color_map: dict, output_dir, make_hvac_plots):
        # Make plots comparing the datasets

        BASIC_PARAMS = {
            'column_for_grouping': column_for_grouping,
            'color_map': color_map,
            'output_dir': output_dir
        }
        logger.info('Making comparison plots')

        logger.info('Making Floor Area and Energy Totals plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_floor_area_and_energy_totals,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE +  [column_for_grouping]),
            include_replicate_weights=True,
            include_base_weight=True)(**BASIC_PARAMS)

        logger.info('Making EUI plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=lambda df, **kwargs: self.plot_eui_boxplots(df, **kwargs, make_hvac_plots=make_hvac_plots),
            lazy_frame=lazy_frame.clone(),
            columns=( [column_for_grouping] + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.BLDG_TYPE, self.HVAC_SYS]),
            include_replicate_weights=False,
            include_base_weight=True)(**BASIC_PARAMS)

        logger.info('Making floor area and energy total by building type plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_floor_area_and_energy_totals_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=( [column_for_grouping] + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE),
            include_replicate_weights=True,
            include_base_weight=True)(**BASIC_PARAMS)

        logger.info('Making end use totals by building type plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_end_use_totals_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=(
                [column_for_grouping]
                + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE
                + self.lazyframe_plotter.WTD_COLS_GROCERY_REFRIG_DETAIL
                + [self.BLDG_TYPE, self.CEN_DIV]
            ))(**BASIC_PARAMS)

        logger.info('Making EUI histogram by building type plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_eui_histograms_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=( [column_for_grouping] + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.BLDG_TYPE]))(**BASIC_PARAMS)

        logger.info('Making EUI boxplots by building type plots')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_eui_boxplots_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=( [column_for_grouping] + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.CEN_DIV, self.BLDG_TYPE]),
            include_base_weight=True)(**BASIC_PARAMS)

        # TODO Utility rate plots when available
        # logger.info('Making Energy Rate plots')
        # LazyFramePlotter.plot_with_lazy(
        #     plot_method=self.plot_energy_rate_boxplots,
        #     lazy_frame=lazy_frame.clone(),
        #     columns=(self.lazyframe_plotter.SUMMARIZE_COLUMNS + self.lazyframe_plotter.UTILITY_COLUMNS + self.lazyframe_plotter.WTD_UTILITY_COLUMNS + [column_for_grouping, self.CEN_DIV, self.BLDG_TYPE]))(**BASIC_PARAMS)

        if make_hvac_plots:
            logger.info('Making HVAC plots')
            logger.info('Making floor area and energy totals by HVAC type plots')
            LazyFramePlotter.plot_with_lazy(
                plot_method=self.plot_floor_area_and_energy_totals_by_hvac_type,
                lazy_frame=lazy_frame.clone(),
                columns=( [column_for_grouping] + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE + [self.HVAC_SYS, self.BLDG_TYPE]))(**BASIC_PARAMS)
            logger.info('Making Floor Area and energy totals grouped by HVAC plots')
            LazyFramePlotter.plot_with_lazy(
                plot_method=self.plot_floor_area_and_energy_totals_grouped_hvac,
                lazy_frame=lazy_frame.clone(),
                columns=( [column_for_grouping] + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE + [self.HVAC_SYS, self.BLDG_TYPE]))(**BASIC_PARAMS)

            logger.info('Making EUI by HVAC type plots')
            LazyFramePlotter.plot_with_lazy(
                plot_method=self.plot_eui_boxplots_by_hvac_type,
                lazy_frame=lazy_frame.clone(),
                columns=( [column_for_grouping] + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.HVAC_SYS, self.CEN_DIV, self.BLDG_TYPE]))(**BASIC_PARAMS)

    def make_enduse_plots(self, lazy_frame: pl.LazyFrame, column_for_grouping, color_map: dict, output_dir):
        BASIC_PARAMS = {
            'column_for_grouping': column_for_grouping,
            'color_map': color_map,
            'output_dir': output_dir,
            'applicability':'stock'
        }
        # Make the stacked end use plots only if there is more than one comstock dataset to compare
        if (lazy_frame.select(pl.col(column_for_grouping).n_unique()).collect()[0, 0] > 1):
            LazyFramePlotter.plot_with_lazy(plot_method=self.plot_energy_by_enduse_and_fuel_type,
                                            lazy_frame=lazy_frame.clone(),
                                            columns=([self.DATASET] + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE + self.lazyframe_plotter.WTD_COLUMNS_ANN_PV + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE),
                                            include_base_weight=False)(**BASIC_PARAMS)

    def make_qoi_plots(self, lazy_frame, column_for_grouping, color_map, output_dir):
        BASIC_PARAMS = {
            'column_for_grouping': column_for_grouping,
            'color_map': color_map,
            'output_dir': output_dir
        }
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_timing, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.QOI_COLUMNS + [column_for_grouping]))(**BASIC_PARAMS)
        # self.plot_qoi_timing(df, column_for_grouping, color_map, output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_max_use, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.QOI_COLUMNS + [column_for_grouping]))(**BASIC_PARAMS)
        # self.plot_qoi_max_use(df, column_for_grouping, color_map, output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_min_use, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.QOI_COLUMNS + [column_for_grouping]))(**BASIC_PARAMS)
        # self.plot_qoi_min_use(df, column_for_grouping, color_map, output_dir)

    def export_to_csv_wide(self):
        file_name = 'ComStock wide.csv'
        file_path = os.path.join(self.output_dir, file_name)

        try:
            self.data.collect().write_csv(file_path)
            logger.info(f'Exported comparison data to {file_path}')
        except Exception as e:
            logger.error(f"CSV export failed: {e}")

    def _validate_building_type(self, building_type: str | None) -> str | None:
        """
        Validates that the provided building type is a recognized ComStock building type.

        Args:
            building_type (str | None): The building type string to validate, or None to skip filtering.

        Returns:
            str | None: The stripped, validated building type string, or None if input was None.

        Raises:
            ValueError: If building_type is not in the list of valid building types.
        """
        if building_type is None:
            return None

        allowed_types = list(self.ORDERED_CATEGORIES[self.BLDG_TYPE])
        requested = building_type.strip()
        if requested not in allowed_types:
            raise ValueError(
                f"Invalid building_type '{building_type}'. Valid options are: {allowed_types}"
            )
        return requested

    def _filter_to_building_type(self, lazy_frame: pl.LazyFrame, building_type: str) -> pl.LazyFrame:
        """
        Filters a LazyFrame to rows matching the specified building type.

        Args:
            lazy_frame (pl.LazyFrame): The input LazyFrame to filter.
            building_type (str): The building type value to filter on.

        Returns:
            pl.LazyFrame: A LazyFrame containing only rows where the building type column
                matches the specified building_type.

        Raises:
            ValueError: If the building type column is not present in the LazyFrame schema.
        """
        schema = lazy_frame.collect_schema().names()
        if self.BLDG_TYPE not in schema:
            raise ValueError(f"Cannot filter by building type; missing required column: {self.BLDG_TYPE}")
        return lazy_frame.filter(pl.col(self.BLDG_TYPE) == building_type)

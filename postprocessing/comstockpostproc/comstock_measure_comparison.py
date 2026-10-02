# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
import os
import logging

from comstockpostproc.lazyframeplotter import LazyFramePlotter
from comstockpostproc import measure_doc_assets
import comstockpostproc.comstock as comstock
import pandas as pd
import polars as pl
from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.plotting_mixin import PlottingMixin


logger = logging.getLogger(__name__)


class ComStockMeasureComparison(NamingMixin, UnitsMixin, PlottingMixin):
    def __init__(self, comstock_object: comstock.ComStock, timeseries_locations_to_plot, make_comparison_plots, make_timeseries_plots, image_type='jpg', name=None, export_measure_doc_assets=False):

        # Initialize members
        assert isinstance(comstock_object.data, pl.LazyFrame)
        # Instantiate the plotting data lazyframe if it doesn't yet exist:
        if not isinstance(comstock_object.plotting_data, pl.LazyFrame):
            logger.info(f'Instantiating plotting lazyframe for comstock dataset {comstock_object.dataset_name}.')
            comstock_object.create_plotting_lazyframe()
        assert isinstance(comstock_object.plotting_data, pl.LazyFrame)
        self.data = comstock_object.plotting_data.clone() #not really a deep copy, only schema is copied but not data.
        assert isinstance(self.data, pl.LazyFrame)

        # Store reference to ComStock object for use in plotting methods
        self.comstock_object = comstock_object
        self.color_map = {}
        self.image_type = image_type
        self.name = name

        upgrade_name_mapping = self.data.select(self.UPGRADE_ID, self.UPGRADE_NAME).unique().collect().sort(self.UPGRADE_ID).to_dict(as_series=False)
        self.dict_upid_to_upname = dict(zip(upgrade_name_mapping[self.UPGRADE_ID], upgrade_name_mapping[self.UPGRADE_NAME]))

        current_dir = os.path.dirname(os.path.abspath(__file__))
        self.dataset_name = comstock_object.dataset_name
        self.output_dir = os.path.join(
            current_dir, '..', 'output', self.dataset_name, 'measure_runs')
        self.column_for_grouping = self.UPGRADE_NAME
        self.dict_measure_dir = {} # this can be called to determine output directory
        self.upgrade_ids_for_comparison = comstock_object.upgrade_ids_for_comparison
        self.comstock_run_name = comstock_object.comstock_run_name
        self.athena_table_name = comstock_object.athena_table_name
        self.s3_base_dir = comstock_object.s3_base_dir
        self.timeseries_locations_to_plot = timeseries_locations_to_plot
        self.make_timeseries_plots = make_timeseries_plots
        self.lazyframe_plotter = LazyFramePlotter()

        # Ensure that the comstock object has savings columns included
        if not comstock_object.include_upgrades:
            logger.error(f'Cannot compare upgrades for {comstock_object.dataset_name}, retry with include_upgrades=True')
            return

        start_time = pd.Timestamp.now()
        # make output directories; create dictionary to store upgrade ID as key and upgrade name as value
        for upgrade, upgrade_name in self.dict_upid_to_upname.items():

            # add dictionary entry and create directory for non-baseline
            if upgrade != '00' and upgrade != 0:
                upgrade_dir_name = 'up' + str(upgrade).zfill(2) + '_' + upgrade_name
                upgrade_dir_name = upgrade_dir_name[:20]  # Truncate name to avoid long filepath errors on Windows
                self.dict_measure_dir[upgrade] = os.path.join(self.output_dir, upgrade_dir_name)
                # make directory if does not exist
                if not os.path.exists(self.dict_measure_dir[upgrade]):
                    os.makedirs(self.dict_measure_dir[upgrade])

                # filter dataset to upgrade and baseline only
                up_base_id = '00'
                upgrade_id = upgrade
                if self.data.select(self.UPGRADE_ID).dtypes == [pl.Int64]: # in test run it's pl.Int64
                    up_base_id = 0
                    upgrade_id = int(upgrade)

                # convert grouping column from cat to str to avoid processing errors with more than 2 measures
                self.data = self.data.with_columns(pl.col(self.UPGRADE_NAME).cast(str))
                assert self.data.select(self.column_for_grouping).dtypes == [pl.String]
                df_upgrade = self.data.filter((pl.col(self.UPGRADE_ID) == upgrade_id) | (pl.col(self.UPGRADE_ID) == up_base_id))

                color_map = {'Baseline': self.COLOR_COMSTOCK_BEFORE, upgrade_name: self.COLOR_COMSTOCK_AFTER}

                # make consumption plots for upgrades if requested by user
                if make_comparison_plots:
                    logger.info(f'Making plots for upgrade {upgrade}')
                    self.make_plots(df_upgrade, self.column_for_grouping, timeseries_locations_to_plot, make_timeseries_plots, color_map, self.dict_measure_dir[upgrade], self.s3_base_dir, self.athena_table_name, self.comstock_run_name)
                else:
                    logger.info("make_comparison_plots is set to false, so not plots were created. Set make_comparison_plots to True for plots.")

                # tables, figures and manifest for the measure documentation, if requested
                if export_measure_doc_assets:
                    self.write_measure_doc_assets(df_upgrade, upgrade_id, up_base_id, upgrade_name, self.dict_measure_dir[upgrade])

        # make plots comparing multiple upgrades together
        for comp_name, comp_up_ids in self.upgrade_ids_for_comparison.items():

                comp_output_dir =  os.path.join(self.output_dir, comp_name)

                # make directory if does not exist
                if not os.path.exists(comp_output_dir):
                    os.makedirs(comp_output_dir)

                assert isinstance(self.data, pl.LazyFrame)
                # convert grouping column from cat to str to avoid processing errors with more than 2 measures
                self.data = self.data.with_columns(pl.col(self.UPGRADE_NAME).cast(str))

                # filter to requested upgrades
                df_upgrade: pl.LazyFrame = self.data.filter(pl.col(self.UPGRADE_ID).is_in(comp_up_ids))

                ## set color map for colors and measure ordering in plots
                color_dict = self.linear_gradient(self.COLOR_COMSTOCK_BEFORE, self.COLOR_COMSTOCK_AFTER, len(comp_up_ids))
                color_map = {}
                for i, up_id in enumerate(comp_up_ids):
                    if up_id in self.dict_upid_to_upname:
                        color_map[self.dict_upid_to_upname[up_id]] = color_dict['hex'][i]
                    else:
                        print(f"up_id {up_id} not found in self.dict_upid_to_upname")

                # make consumption plots for upgrades if requested by user
                if make_comparison_plots:
                    self.make_comparative_plots(df_upgrade, self.column_for_grouping, timeseries_locations_to_plot, make_timeseries_plots, color_map, comp_output_dir, self.s3_base_dir, self.athena_table_name, self.comstock_run_name)
                else:
                    logger.info("make_comparison_plots is set to false, so not plots were created. Set make_comparison_plots to True for plots.")
        end_time = pd.Timestamp.now()
        logger.info(f"Time taken to make all plots is {end_time - start_time}")

    def write_measure_doc_assets(self, lazy_frame, upgrade_id, baseline_id, upgrade_name, measure_dir):
        """Write measure_dir/doc_assets/: the tables, figures and manifest a measure document is
        built from (see comstockpostproc.measure_doc_assets).

        A failure is logged, not raised, so it cannot cost the rest of a postprocessing run.
        """
        run = measure_doc_assets.run_info_from_comstock(self.comstock_object)
        inputs = measure_doc_assets.plotting_cache_files(run['run_dir'], [baseline_id, upgrade_id]) if run.get('run_dir') else []
        try:
            logger.info(f'Writing measure documentation assets for upgrade {upgrade_id}')
            measure_doc_assets.export(lazy_frame, upgrade_id, baseline_id, upgrade_name, measure_dir,
                                      plotter=self, run=run, inputs=inputs)
        except Exception:
            logger.exception(f'Measure documentation assets for upgrade {upgrade_id} were not written')

    def make_plots(self, lazy_frame: pl.LazyFrame, column_for_grouping, timeseries_locations_to_plot, make_timeseries_plots, color_map, output_dir, s3_base_dir, athena_table_name, comstock_run_name):
        time_start = pd.Timestamp.now()

        BASIC_PARAMS = {
            'column_for_grouping': column_for_grouping,
            'color_map': color_map,
            'output_dir': output_dir
        }

        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_energy_by_enduse_and_fuel_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE + self.lazyframe_plotter.WTD_COLUMNS_ANN_PV + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_emissions_by_fuel_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_GHG_COLUMNS))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_utility_bills_by_fuel_type, lazy_frame=lazy_frame.clone(), columns=(
            self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_UTILITY_COLUMNS))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_floor_area_and_energy_totals,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_floor_area_and_energy_totals_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE))(**BASIC_PARAMS)
        _lf_schema = lazy_frame.collect_schema().names()
        _grocery_detail_cols = [c for c in self.lazyframe_plotter.WTD_COLS_GROCERY_REFRIG_DETAIL if c in _lf_schema]
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_end_use_totals_by_building_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE + _grocery_detail_cols + [self.BLDG_TYPE, self.CEN_DIV]))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_eui_histograms_by_building_type,
                                        lazy_frame=lazy_frame.clone(), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.BLDG_TYPE]))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_eui_boxplots_by_building_type,
                                        lazy_frame=lazy_frame.clone(), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_ANN_TOTL_COLUMNS + [self.CEN_DIV, self.BLDG_TYPE]))(**BASIC_PARAMS)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_savings_distributions_enduse_and_fuel, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.SAVINGS_DISTRI_ENDUSE_COLUMNS + [self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_savings_distributions_by_building_type, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.SAVINGS_DISTRI_BUILDINTYPE + [self.BLDG_TYPE, self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_savings_distributions_by_climate_zone, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.SAVINGS_DISTRI_BUILDINTYPE + [self.CZ_ASHRAE, self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_savings_distributions_by_hvac_system_type, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.SAVINGS_DISTRI_BUILDINTYPE + [self.HVAC_SYS, self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_utility_savings_distributions_by_fuel, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_SAVINGS_COLUMNS + [self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_utility_savings_distributions_by_building_type, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_SAVINGS_COLUMNS + [self.BLDG_TYPE, self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_utility_savings_distributions_by_climate_zone, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_SAVINGS_COLUMNS + [self.CZ_ASHRAE, self.UPGRADE_ID]))(output_dir=output_dir)
        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_utility_savings_distributions_by_hvac_system, lazy_frame=lazy_frame.clone(
        ), columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.EUI_SAVINGS_COLUMNS + [self.HVAC_SYS, self.UPGRADE_ID]))(output_dir=output_dir)

        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_timing, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.QOI_COLUMNS))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_max_use, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.QOI_COLUMNS))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_qoi_min_use, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.QOI_COLUMNS))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_unmet_hours, lazy_frame=lazy_frame.clone(),
                                        columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.UNMET_HOURS_COLS))(**BASIC_PARAMS)

        if make_timeseries_plots:
            TIMESERIES_PARAMS = {
                'comstock_run_name': self.comstock_run_name,
                'timeseries_locations_to_plot': timeseries_locations_to_plot,
                'color_map': color_map,
                'output_dir': output_dir,
                'comstock_obj': self.comstock_object}

            LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_timeseries_peak_week_by_state, lazy_frame=lazy_frame.clone(),
                                            columns=(self.lazyframe_plotter.BASE_COLUMNS + [self.UPGRADE_ID, self.BLDG_TYPE]))(**TIMESERIES_PARAMS) #self.BLDG_WEIGHT,
            LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_timeseries_season_average_by_state, lazy_frame=lazy_frame.clone(),
                                            columns=(self.lazyframe_plotter.BASE_COLUMNS + [self.UPGRADE_ID, self.BLDG_TYPE]))(**TIMESERIES_PARAMS) #self.BLDG_WEIGHT
            LazyFramePlotter.plot_with_lazy(plot_method=self.plot_measure_timeseries_annual_average_by_state_and_enduse, lazy_frame=lazy_frame.clone(),
                                            columns=(self.lazyframe_plotter.BASE_COLUMNS + [self.UPGRADE_ID, self.BLDG_TYPE]))(**TIMESERIES_PARAMS) #self.BLDG_WEIGHT
        time_end = pd.Timestamp.now()
        logger.info(f"Time taken to make plots is {time_end - time_start}")

    def make_comparative_plots(self, lazy_frame: pl.LazyFrame, column_for_grouping, timeseries_locations_to_plot, make_timeseries_plots, color_map, output_dir, s3_base_dir, athena_table_name, comstock_run_name):
        # Make plots comparing the upgrades

        assert isinstance(lazy_frame, pl.LazyFrame)
        BASIC_PARAMS = {
            'column_for_grouping': column_for_grouping,
            'color_map': color_map,
            'output_dir': output_dir
        }

        logger.info(f'Making comparison plots for upgrade groupings')
        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_energy_by_enduse_and_fuel_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_ANN_ENDUSE + self.lazyframe_plotter.WTD_COLUMNS_ANN_PV + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_emissions_by_fuel_type,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_GHG_COLUMNS))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(plot_method=self.plot_utility_bills_by_fuel_type, lazy_frame=lazy_frame.clone(), columns=(
            self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_UTILITY_COLUMNS))(**BASIC_PARAMS)

        LazyFramePlotter.plot_with_lazy(
            plot_method=self.plot_floor_area_and_energy_totals,
            lazy_frame=lazy_frame.clone(),
            columns=(self.lazyframe_plotter.BASE_COLUMNS + self.lazyframe_plotter.WTD_COLUMNS_SUMMARIZE))(**BASIC_PARAMS)

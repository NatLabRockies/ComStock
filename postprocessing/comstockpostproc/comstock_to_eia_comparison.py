# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

import os
import logging

import pandas as pd
import polars as pl
from typing import List

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.plotting_mixin import PlottingMixin
from comstockpostproc.eia import EIA
from comstockpostproc.comstock import ComStock
from comstockpostproc.lazyframeplotter import LazyFramePlotter
from comstockpostproc.output_folders import comparison_folder
logger = logging.getLogger(__name__)

class ComStockToEIAComparison(NamingMixin, UnitsMixin, PlottingMixin):
    def __init__(self, comstock_list: List[ComStock], eia_list: List[EIA], upgrade_id=0, image_type='jpg', name=None, make_comparison_plots=True):
        """
        Creates the ComStock to EIA comparison plots.

        Args:
            comstock_list (List[ComStock]): List of ComStock dataset objects
            eia_list (List[EIA]): List of EIA dataset objects.
            upgrade_id (Union[str, int], optional): The upgrade ID to include in the chart, or 'All' to include all upgrades for the ComStock run(s).
            image_type (str, optional): Image file type to use. Defaults to 'jpg'.
            name (str, optional): Folder under output/ for a comparison of several runs, which needs one. If None,
                a comparison of one run writes into that run's folder, eia_comparison/. Defaults to None.
            make_comparison_plots (bool, optional): Flag to create comparison plots. Defaults to True.
        """
        # Initialize members
        self.comstock_list = comstock_list
        self.eia_list = eia_list
        self.data = None
        self.monthly_data = None
        self.monthly_data_gap = None
        self.color_map = {}
        self.monthly_color_map = {}
        self.image_type = image_type
        self.name = name

        # Concatenate the datasets and create a color map
        monthly_dfs_to_concat = []
        annual_dfs_to_concat = []
        dataset_names = []
        for dataset in (eia_list + comstock_list):
        # for dataset in (comstock_list + eia_list):
            logger.info(f'Adding dataset: {dataset.dataset_name}')
            dataset_names.append(dataset.dataset_name)
            if isinstance(dataset, ComStock): #dataset is ComStock
                assert isinstance(dataset.data, pl.LazyFrame)
                # Annual emissions
                annual_upgrade_ids = [upgrade_id]
                if upgrade_id == 'All':
                    annual_upgrade_ids = dataset.data.select(pl.col('upgrade')).unique().collect().to_pandas()['upgrade'].to_list()
                annual_data = dataset.data.filter(pl.col('upgrade').is_in(annual_upgrade_ids))
                if not annual_upgrade_ids == [0]:
                    annual_data = annual_data.with_columns(
                        pl.concat_str([pl.col(dataset.DATASET), pl.col(dataset.UPGRADE_NAME)], separator=" - ").alias(dataset.DATASET),
                    )
                color_dict = self.linear_gradient(dataset.COLOR_COMSTOCK_BEFORE, dataset.COLOR_COMSTOCK_AFTER, len(annual_upgrade_ids))
                # for idx, dataset_upgrade_name in enumerate(annual_data.get_column(dataset.DATASET).unique().sort().to_list()):
                # logger.info(f"annual_data shape: {annual_data.select(dataset.DATASET).unique().collect().to_pandas()[dataset.DATASET].tolist().sort()}")
                for idx, dataset_upgrade_name in enumerate(sorted(annual_data.select(dataset.DATASET).unique().collect().to_pandas()[dataset.DATASET].to_list())):
                    self.color_map[dataset_upgrade_name] = color_dict['hex'][idx]
                assert isinstance(annual_data, pl.LazyFrame)
                annual_dfs_to_concat.append(annual_data)

                # logger.info(f"annual_data shape: {annual_data.columns} , {annual_data.collect().to_pandas().shape}") #more than 1000 columns.
                # Monthly energy
                if dataset.monthly_data is None:
                    logger.warning(f'No monthly_data was available for {dataset.dataset_name}, not including in EIA comparison.')
                    continue
                monthly_upgrade_ids = [upgrade_id]
                if upgrade_id == 'All':
                    monthly_upgrade_ids = dataset.monthly_data.get_column('upgrade').unique().to_list()
                monthly_data = dataset.monthly_data.filter(pl.col('upgrade').is_in(monthly_upgrade_ids))
                if not monthly_upgrade_ids == [0]:
                    monthly_data = monthly_data.with_columns(
                        pl.concat_str([pl.col(dataset.DATASET), pl.col('upgrade_name')], separator=" - ").alias(dataset.DATASET),
                    )
                color_dict = self.linear_gradient(dataset.COLOR_COMSTOCK_BEFORE, dataset.COLOR_COMSTOCK_AFTER, len(monthly_upgrade_ids))
                assert isinstance(monthly_data, pl.DataFrame)             
                # logger.info(f"monthly_data shape: {monthly_data.to_pandas().shape}, {monthly_data.columns}") #['upgrade', 'Month', 'FIPS Code', 'building_type', 'total_site_gas_kbtu', 'total_site_electricity_kwh', 'upgrade_name']

                for idx, dataset_upgrade_name in enumerate(monthly_data.get_column(dataset.DATASET).unique().sort().to_list()):
                    self.monthly_color_map[dataset_upgrade_name] = color_dict['hex'][idx]
                
                # logger.info(f"monthly_data shape: {monthly_data.columns} , {monthly_data.to_pandas().shape}")
                monthly_dfs_to_concat.append(monthly_data.lazy())
            else:  #dataset is EIA
                assert isinstance(dataset, EIA), f"dataset is not EIA, it is {type(dataset)}"
                assert isinstance(dataset.emissions_data, pl.DataFrame), f"type of dataset.emissions_data is {type(dataset.emissions_data)}, if it's None, check EIA reload flag"
                # Annual emissions
                annual_dfs_to_concat.append(dataset.emissions_data.lazy())
                self.color_map[dataset.dataset_name] = dataset.color

                # Monthly energy
                assert isinstance(dataset.monthly_data, pd.DataFrame), f"type of dataset.monthly_data is {type(dataset.monthly_data)}"
                monthly_dfs_to_concat.append(pl.from_pandas(dataset.monthly_data).lazy())
                self.monthly_color_map[dataset.dataset_name] = dataset.color
        
        # Where it writes (output_folders.py): a comparison of one run goes in that run's folder, eia_comparison/; one
        # of several runs needs the name its driver sets, output/<name>/
        self.output_dir = comparison_folder(comstock_list, self.name, 'eia_comparison')

        # Combine into a single dataframe for convenience
        # self.monthly_data = pl.concat(monthly_dfs_to_concat, join='outer', ignore_index=True)

        common_columns = set(monthly_dfs_to_concat[0].columns)
        for df in monthly_dfs_to_concat:
            common_columns = common_columns.intersection(set(df.columns))
        monthly_dfs_to_concat = [df.select(common_columns) for df in monthly_dfs_to_concat]
        self.monthly_data = pl.concat(monthly_dfs_to_concat, how="vertical_relaxed")
        self.monthly_data = LazyFramePlotter.select_columns(self.monthly_data, common_columns)
        logger.info(f"monthly_data shape: {self.monthly_data.shape}, column types are {self.monthly_data.dtypes}") #only 7 columns left.
        assert isinstance(self.monthly_data, pd.DataFrame)

        # self.data = pl.concat(annual_dfs_to_concat, join='inner', ignore_index=True)
        common_columns = set(annual_dfs_to_concat[0].columns)
        for df in annual_dfs_to_concat:
            common_columns = common_columns.intersection(set(df.columns))
        dfs_to_concat = [df.select(common_columns) for df in annual_dfs_to_concat]
        self.data: pl.LazyFrame = pl.concat(dfs_to_concat, how="vertical_relaxed")
        self.data: pd.DataFrame = LazyFramePlotter.select_columns(self.data, common_columns)
        logger.info(f"annual_data shape: {self.data.shape}, column types are {self.data.dtypes}") #only 7 columns left.
        assert isinstance(self.data, pd.DataFrame)

        # Make directories
        if not os.path.exists(self.output_dir):
            os.makedirs(self.output_dir)
        logger.info(f"output_dir: {self.output_dir}")

        # Make ComStock to EIA comparison plots
        if make_comparison_plots:
            self.make_emissions_plots(self.data, self.color_map, self.output_dir)
            self.make_plots(self.monthly_data, self.monthly_color_map, self.output_dir)
        else:
            logger.info("make_comparison_plots is set to false, so not plots were created. Set make_comparison_plots to True for plots.")

    def export_to_csv_wide(self):
        # Exports comparison data to CSV in wide format
        file_name = f'ComStock Monthly Long.csv'
        file_path = os.path.join(self.output_dir, file_name)
        self.monthly_data.to_csv(file_path, index=False)

    def make_plots(self, df, color_map, output_dir):
        # Make plots comparing the datasets

        logger.info('Making energy comparison plots')
        self.plot_annual_energy_consumption_for_eia(df, color_map, output_dir)
        self.plot_monthly_energy_consumption_for_eia(df, color_map, output_dir)

    def make_emissions_plots(self, df, color_map, output_dir):
        # Make plots comparing annual emissions by fuel

        logger.info('Making emissions comparison plots')
        self.plot_annual_emissions_comparison(df, self.DATASET, color_map, output_dir)
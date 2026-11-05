# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

import os
import logging

import pandas as pd
from typing import List

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.plotting_mixin import PlottingMixin
from comstockpostproc.ami import AMI
from comstockpostproc.comstock import ComStock
from comstockpostproc.output_folders import comparison_folder

logger = logging.getLogger(__name__)

class ComStockToAMIComparison(NamingMixin, UnitsMixin, PlottingMixin):
    def __init__(self, comstock_object:ComStock, ami_object:AMI, image_type='jpg', name=None, make_comparison_plots=True):

        # Initialize members
        self.comstock_object = comstock_object
        self.ami_object = ami_object
        self.ami_timeseries_data = None
        self.ami_plot_data = None
        self.color_map = {}
        self.image_type = image_type
        self.name = name

        # Concatenate the datasets and create a color map
        dfs_to_concat = []
        dataset_names = []
        for dataset in [comstock_object, ami_object]:
            if dataset.ami_timeseries_data is None:
                logger.warning(f'No timeseries data was available for {dataset.dataset_name}, unable to make AMI comparison.')
                continue
            if isinstance(dataset, ComStock):
                df = dataset.ami_timeseries_data.copy(deep=True)
                df['run'] = self.comstock_object.dataset_name
                df['year'] = self.comstock_object.year
                # Normalize building type names to match AMI format
                df['building_type'] = df['building_type'].map(self.BLDG_TYPE_TO_SNAKE_CASE).fillna(df['building_type'].str.lower())
                dfs_to_concat.append(df)
            elif isinstance(dataset, AMI):
                df = dataset.ami_timeseries_data.copy(deep=True)
                df['run'] = self.ami_object.dataset_name
                df['enduse'] = 'total'
                dfs_to_concat.append(df)
            self.color_map[dataset.dataset_name] = dataset.color
            dataset_names.append(dataset.dataset_name)

        # Where it writes (output_folders.py): this run's folder, ami_comparison/, unless the driver names it
        self.output_dir = comparison_folder([comstock_object], self.name, 'ami_comparison')

        # Combine into a single dataframe for convenience
        if len(dfs_to_concat) == 0:
            self.ami_timeseries_data = pd.DataFrame()
        else:
            self.ami_timeseries_data = pd.concat(dfs_to_concat, join='outer')

        # Make directories
        for p in [self.output_dir]:
            if not os.path.exists(p):
                os.makedirs(p)

        # Make ComStock to AMI comparison plots
        if make_comparison_plots:
            self.make_plots()
        else:
            logger.info("make_comparison_plots is set to false, so not plots were created. Set make_comparison_plots to True for plots.")

    def export_to_csv_wide(self):
        # Exports comparison data to CSV in wide format
        file_name = f'ComStock AMI Comparison Timeseries Long.csv'
        file_path = os.path.join(self.output_dir, file_name)
        self.ami_timeseries_data.to_csv(file_path, index=True)

    def export_plot_data_to_csv_wide(self):
        # Exports comparison data to CSV in wide format
        file_name = f'ComStock AMI Comparison Plot Data.csv'
        file_path = os.path.join(self.output_dir, file_name)
        self.ami_plot_data.to_csv(file_path, index=False)

    """
    Make plots comparing the datasets
    """
    def make_plots(self):
        logger.info('Making comparison plots')
        comstock_data_label = list(self.color_map.keys())[0]
        ami_data_label = list(self.color_map.keys())[1]

        # for each region
        dfs_to_concat = []
        for region in self.ami_object.ami_region_map:
            region_df = self.ami_timeseries_data.loc[self.ami_timeseries_data['region_name'] == region['source_name']]

            # for each building type
            for building_type in self.ami_object.building_types:
                type_region_df = region_df.loc[region_df['building_type'] == building_type]
                bldg_type_output_dir = os.path.join(self.output_dir, building_type)
                if not os.path.exists(bldg_type_output_dir):
                    os.makedirs(bldg_type_output_dir)

                # check that both ami and comstock data have values defined
                ami_check : pd.DataFrame= type_region_df[type_region_df['run'] == ami_data_label]
                comstock_check : pd.DataFrame = type_region_df[type_region_df['run'] == comstock_data_label]

                if ami_check.empty:
                    logger.debug(f"dataset does not contain {building_type} buildings in {ami_data_label} for region {region['source_name']}. Skipping building specific graphics.")
                    continue
                if comstock_check.empty:
                    logger.debug(f"dataset does not contain {building_type} buildings in {comstock_data_label} for region {region['source_name']}. Skipping building specific graphics.")
                    continue

                # check that ami data has enough buildings to provide a useful comparison
                ami_min_count = int(ami_check['bldg_count'].min())
                if ami_min_count < 3:
                    print(f"dataset contains fewer than 3 {building_type} buildings in {ami_data_label} for region {region['source_name']}. Skipping building specific graphics.")
                    continue

                type_region_plot_data = self.plot_day_type_comparison_stacked_by_enduse(type_region_df, region, building_type, self.color_map, bldg_type_output_dir)
                dfs_to_concat.append(type_region_plot_data)
                self.plot_day_type_comparison_stacked_by_enduse(type_region_df, region, building_type, self.color_map, bldg_type_output_dir, normalization='Daytype')
                self.plot_day_type_comparison_stacked_by_enduse(type_region_df, region, building_type, self.color_map, bldg_type_output_dir, normalization='Annual')
                self.plot_load_duration_curve(type_region_df, region, building_type, self.color_map, bldg_type_output_dir)
        # combine plot data
        self.ami_plot_data = pd.concat(dfs_to_concat, join='outer', ignore_index=True)
import os
import boto3
import logging
import botocore
import pandas as pd
from buildstock_query import BuildStockQuery
from comstockpostproc.athena_config import ATHENA_WORKGROUP
from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.gap.eia861 import EIA861
from comstockpostproc.gap.ba_geography import BAGeography

from comstockpostproc.s3_utilities_mixin import S3UtilitiesMixin

# Create logger for AWS queries
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class CommercialProfile(NamingMixin, S3UtilitiesMixin):
    def __init__(self, truth_data_version='v01', reload_from_saved=True, save_processed=True, comstock_version='amy2018_r1_2025', allocation_method='EIA'):
        """
        A class to query commercial hourly electricity demand profiles from ComStock, allocated to Balaancing Authority.

        Args:
            truth_data_version (String): The version of truth data. 'v01'
            reload_from_saved (Bool): reload from processed data if available
            save_processed (Bool): Flag to save out processed files
            comstock_version (String): The version of ComStock to query
            allocation_method (String): ['EIA', 'BAGeo'] the method to allocate commercial state-level profiles to BA-level.

        """

        self.truth_data_version = truth_data_version
        self.reload_from_saved = reload_from_saved
        self.save_processed = save_processed
        self.comstock_version = comstock_version
        self.allocation_method = allocation_method
        self.comstock_profiles_filename = f'comstock_{self.comstock_version}_load_by_state.parquet'

        current_dir = os.path.dirname(os.path.abspath(__file__))
        self.truth_data_dir = os.path.join(current_dir, '..', '..', 'truth_data', self.truth_data_version)

        self.processed_dir = os.path.join(self.truth_data_dir, 'gap_processed')
        self.output_dir = os.path.join(current_dir, 'output')

        self.new_sampling = True
        if self.comstock_version == '2024_amy2018_release_1':
            self.new_sampling = False
            self.metadata_db = f'comstock_{self.comstock_version}_metadata_state_vu'
            self.full_metadata_db = f'comstock_{self.comstock_version}_metadata_state_vu'
            self.timeseries_db = f'comstock_{self.comstock_version}_by_state_vu'
        elif (self.comstock_version == 'amy2018_r2_2025' or self.comstock_version == 'amy2018_r3_2025'):
            self.metadata_db = f'comstock_{self.comstock_version}_md_agg_by_state_parquet'
            self.full_metadata_db = f'comstock_{self.comstock_version}_md_by_state_and_county_parquet'
            self.timeseries_db = f'comstock_{self.comstock_version}_ts_by_state'

        # initialize s3 client
        self.s3_client = boto3.client('s3', config=botocore.client.Config(max_pool_connections=50))

        # calculate BA profiles
        if self.allocation_method == 'EIA':
            self.data = self.com_ba_profiles_from_eia()
        elif self.allocation_method == 'BAGeo':
            self.data = self.com_ba_profiles_from_ba_geography()
        else:
            logger.error(f'Cannot allocate commercial profiles to BA with allocation method {self.allocation_method} - not supported.')
            exit()

    def comstock_elec_hourly(self):
        """
        Queries ComStock for ending-hour total electricity by state
        """
        run = BuildStockQuery(workgroup=ATHENA_WORKGROUP,
                              db_name='buildstock_sdr',
                              table_name=(
                                  self.metadata_db,
                                  self.timeseries_db,
                                  None
                              ),
                              db_schema='comstock_oedi',
                              buildstock_type='comstock',
                              skip_reports=True)

        new_sampling_string = " and \"t1\".\"state\" = \"t2\".\"state\""

        query = f"""
        select
            case
                when extract(minute from "t2"."timestamp") = 0
                    and extract(second from "t2"."timestamp") = 0
                    then date_trunc('hour', "t2"."timestamp")
                else date_trunc('hour', "t2"."timestamp") + interval '1' hour
            end as "rounded_hour",
            sum("t2"."out.electricity.total.energy_consumption" * "t1"."weight") as "total_electricity",
            "t1"."state" as "state"
        from
            "{self.metadata_db}" as "t1"
        inner join
            "{self.timeseries_db}" as "t2"
        on
            "t1"."bldg_id" = "t2"."bldg_id"
        where
            "t1"."upgrade" = 0 and
            "t2"."upgrade" = 0
            {new_sampling_string if self.new_sampling else ""}
        group by
            case
                when extract(minute from "t2"."timestamp") = 0
                    and extract(second from "t2"."timestamp") = 0
                    then date_trunc('hour', "t2"."timestamp")
                else date_trunc('hour', "t2"."timestamp") + interval '1' hour
            end,
            "t1"."state"
        order by
            "rounded_hour"
        """

        logger.info('Querying Athena for timeseries ComStock results. This will take a while.')

        df = run.execute(query)

        df.to_parquet(os.path.join(self.truth_data_dir, self.comstock_profiles_filename))

        return df

    def comstock_hourly_by_state(self):
        """
        Loads ComStock results from existing truth data file or by querying S3
        """

        local_path = os.path.join(self.truth_data_dir, self.comstock_profiles_filename)
        if os.path.exists(local_path):
            logger.info('Reloading ComStock timestep state profiles from truth data')
            com_load = pd.read_parquet(local_path)
        else:
            com_load = self.comstock_elec_hourly()

        com_load.set_index('rounded_hour', inplace=True)

        return com_load

    def comstock_total_by_utility(self):
        run = BuildStockQuery(workgroup=ATHENA_WORKGROUP,
                              db_name='buildstock_sdr',
                              table_name=(
                                  self.metadata_db,
                                  self.timeseries_db,
                                  None
                              ),
                              db_schema='comstock_oedi',
                              buildstock_type='comstock',
                              skip_reports=True)

        if self.new_sampling:
            col_name = "\"t1\".\"out.electricity.total.energy_consumption..kwh\""
        else:
            col_name = "\"t1\".\"out.electricity.total.energy_consumption\""

        query = f"""
        select
            sum({col_name} * "t1"."weight") as "total_electricity",
            "t1"."state" as "state",
            "t1"."out.utility_bills.electricity_utility_eia_id" as "utility_id"
        from
            "{self.metadata_db}" as "t1"
        where
            "t1"."upgrade" = 0
        group by
            "t1"."state",
            "t1"."out.utility_bills.electricity_utility_eia_id"
        """

        logger.info('Querying Athena for total electricity by state and utility.')

        df = run.execute(query)

        # df.to_parquet(os.path.join(self.truth_data_dir, self.comstock_total_filename))

        return df

    def comstock_total_by_tract_and_utility(self):

        local_filename = f'comstock_{self.comstock_version}_total_elec_by_tract_and_utility.parquet'
        local_path = os.path.join(self.truth_data_dir, local_filename)
        if os.path.exists(local_path):
            logger.info('Reloading ComStock Total Electricity by Tract and Utility ID from truth data')
            df = pd.read_parquet(local_path)
        else:
            logger.info('Querying ComStock on OEDI for Total Electricity by Tract and Utility ID')
            run = BuildStockQuery(workgroup=ATHENA_WORKGROUP,
                                db_name='buildstock_sdr',
                                table_name=(
                                    f'{self.full_metadata_db}',
                                    f'{self.timeseries_db}',
                                    None
                                ),
                                db_schema='comstock_oedi',
                                buildstock_type='comstock',
                                skip_reports=True)

            if self.new_sampling:
                col_name = "\"t1\".\"out.electricity.total.energy_consumption..kwh\""
                add_select = ""
                add_group = ""
            else:
                col_name = "\"t1\".\"out.electricity.total.energy_consumption\""
                add_select = ", \"t1\".\"out.utility_bills.electricity_utility_eia_id\" as \"in.electric_utility_eia_code\""
                add_group = ", \"t1\".\"out.utility_bills.electricity_utility_eia_id\""

            query = f"""
            select
                sum({col_name} * "t1"."weight") as "total_electricity",
                "t1"."in.nhgis_tract_gisjoin" as "in.nhgis_tract_gisjoin"
                {add_select}
            from
                "{self.full_metadata_db}" as "t1"
            where
                "t1"."upgrade" = 0
            group by
                "t1"."in.nhgis_tract_gisjoin"
                {add_group}
            """

            logger.info('Querying Athena for total electricity by tract and utility.')

            df = run.execute(query)

            df.to_parquet(os.path.join(self.truth_data_dir, local_filename))

        return df

    def state_fips_to_state_abbrv(self):
        df = self.read_delimited_truth_data_file_from_S3(s3_file_path= f'truth_data/{self.truth_data_version}/national_state2020.txt',
                                                         delimiter= '|',
                                                         args={'dtype': {'STATEFP': 'str'},
                                                               'usecols': ['STATEFP', 'STATE'],
                                                               'index_col': 'STATEFP'})
        return df

    def tract_utility_ba_map(self):
        """
        returns a mapping of tract, utility ID, and BA Code
        """

        TRACT = 'in.nhgis_tract_gisjoin'
        ELEC_UTIL_ID = 'in.electric_utility_eia_code'

        # comstock utility_id is missing for a large number of tracts, re-map from improved tract_to_elec_util_v2.csv - TODO remove this after ComStock results are updated
        tract_to_util_map = self.read_delimited_truth_data_file_from_S3(f'truth_data/{self.truth_data_version}/tract_to_elec_util_v2.csv', delimiter=',', args={'dtype': {self.UTIL_ID: 'str'}})

        state_fips_to_abbrv = self.state_fips_to_state_abbrv()
        tract_to_util_map = pd.merge(tract_to_util_map, state_fips_to_abbrv, how='left', left_on=tract_to_util_map[self.TRACT_ID].str[1:3], right_on=state_fips_to_abbrv.index)
        tract_to_util_map.drop(columns=('key_0'), inplace=True)
        tract_to_util_map.rename(columns={'STATE': self.STATE_ABBRV}, inplace=True)

        # get complete map of utility_id to ba_code from EIA 861 Sales, Short and Meters
        cols = ['Utility Number', 'Utility Name', 'State', 'BA Code']
        meters = EIA861(type='Meters').data
        sales = EIA861(measure='Customers').data
        short = EIA861(type='Short', measure='Customers').data

        def filter_sales(df):
            part_mask = df['Part'] != 'C'
            owner_mask = df['Ownership'] != 'Behind the Meter'
            num_mask = df['Utility Number'] != 99999

            df = df.loc[part_mask & owner_mask & num_mask]
            return df

        def filter_short(df):
            na_mask = df['Total Customers'].notna()
            df = df.loc[na_mask]
            return df

        sales = filter_sales(sales)
        sales = sales[cols]

        short = filter_short(short)
        short = short[cols]

        meters = meters[cols]

        util_ba_map = pd.merge(sales, short, how='outer')
        # drop NBSO
        util_ba_map = util_ba_map[util_ba_map['BA Code'] != 'NBSO']

        # only include meters data if the combination of Utility Number and State don't already exist
        util_ba_map['util_state'] = list(zip(util_ba_map['Utility Number'], util_ba_map['State']))
        meters['util_state'] = list(zip(meters['Utility Number'], meters['State']))
        meters_filtered = meters[~meters['util_state'].isin(util_ba_map['util_state'])].drop(columns=['util_state'])
        util_ba_map = pd.merge(util_ba_map.drop(columns=['util_state']), meters_filtered, how='outer')

        util_ba_map = util_ba_map.astype({'Utility Number': str})
        util_ba_map.rename(columns={'Utility Number': self.UTIL_ID, 'State': self.STATE_ABBRV}, inplace=True)

        tract_utility_ba_map = pd.merge(tract_to_util_map, util_ba_map[[self.UTIL_ID, self.STATE_ABBRV, 'BA Code']], how='left', on=[self.UTIL_ID, self.STATE_ABBRV])

        return tract_utility_ba_map


    def com_ba_profiles_from_eia(self):
        """
        Apportions ComStock profiles to Balancing Authority by aggregating tract totals by assigned Utility ID and Utility ID to BA mapping from EIA 861 data.
        """

        processed_filename = f'com_ba_profiles_{self.allocation_method}_{self.comstock_version}.parquet'
        processed_path = os.path.join(self.processed_dir, processed_filename)
        if self.reload_from_saved:
            if os.path.exists(processed_path):
                logger.info('Reloading BA Commercial Hourly Profiles from saved')
                df = pd.read_parquet(processed_path)
                return df
            else:
                logger.info(f'No processed data found for {processed_filename}. Processing from truth data.')

        # query comstock by tract and utility id
        com_by_tract = self.comstock_total_by_tract_and_utility()

        tract_utility_ba_map = self.tract_utility_ba_map()

        # merge state_abbrev and BA code into comstock by tract
        com_by_tract = pd.merge(com_by_tract, tract_utility_ba_map, how='left', on=self.TRACT_ID)

        com_by_state_ba = com_by_tract.groupby([self.STATE_ABBRV,'BA Code'])['total_electricity'].sum().to_frame()

        # calculate state ba fractions
        com_by_ba = com_by_tract.groupby(self.STATE_ABBRV)['total_electricity'].sum().to_frame()
        com_state_ba_fracs = com_by_state_ba.divide(com_by_ba, level=0)
        com_state_ba_fracs.rename(columns={'total_electricity':'total_electricity_fraction'}, inplace=True)

        # multiply state BA fractions by state profiles to get state BA profiles
        com_hourly_by_state = self.comstock_hourly_by_state()

        # pivot to one col per state
        com_hourly_by_state = com_hourly_by_state.pivot_table('total_electricity', index='rounded_hour', columns='state', aggfunc='sum')

        com_ba_state_profiles_data = {}
        for idx, row in com_state_ba_fracs.iterrows():
            if idx[0] in com_hourly_by_state.columns:
                com_ba_state_profiles_data[idx] = com_hourly_by_state[idx[0]].mul(row['total_electricity_fraction'])

        com_ba_state_profiles = pd.DataFrame(com_ba_state_profiles_data)

        # convert from kWh to MWh
        com_ba_state_profiles = com_ba_state_profiles / 1e3

        com_ba_profiles = com_ba_state_profiles.T.groupby(level=1).sum().T

        if self.save_processed:
            com_ba_profiles.to_parquet(processed_path)

        return com_ba_profiles

    def com_ba_profiles_from_ba_geography(self):
        """
        Apportions ComStock state profiles to Balancing Authority by dividing state total load by fraction of total commercial building area found in each territory from
        Structures dataset. This assumes that commercial-coded structure areas are equally proportional to electricity use nationwide (in each state).
        """

        processed_filename = f'com_ba_profiles_{self.allocation_method}.parquet'
        processed_path = os.path.join(self.processed_dir, processed_filename)
        if self.reload_from_saved:
            if os.path.exists(processed_path):
                logger.info('Reloading BA Commercial Hourly Profiles from saved')
                df = pd.read_parquet(processed_path)
                return df
            else:
                logger.info(f'No processed data found for {processed_filename}. Processing from truth data.')

        # load comstock profiles
        com_hourly_by_state = self.comstock_hourly_by_state()

        # pivot to one col per state
        com_hourly_by_state = com_hourly_by_state.pivot_table('total_electricity', index='rounded_hour', columns='state', aggfunc='sum')

        # load county to BA mapping
        ba_tract_areas = BAGeography().balancing_authority_bldg_areas_data()
        ba_tract_com_areas = ba_tract_areas.loc[:,'All Commercial'].to_frame()

        # merge tract data to state
        ba_tract_com_areas['state_fips'] = ba_tract_com_areas.index.get_level_values('CENSUSCODE').str[:2]
        ba_tract_com_areas.set_index('state_fips', append=True, inplace=True)
        ba_state_areas = ba_tract_com_areas.groupby(['BA Code', 'state_fips']).sum()

        #  get fips to abbrev map and group BA areas by state abbrev
        state_labels = self.read_delimited_truth_data_file_from_S3(f'truth_data/{self.truth_data_version}/national_state2020.txt', '|')
        state_labels['STATEFP'] = state_labels['STATEFP'].astype(str).str.zfill(2)
        state_labels = state_labels[['STATE', 'STATEFP']].set_index('STATEFP')

        ba_state_areas = ba_state_areas.join(state_labels, on='state_fips')
        ba_state_areas.set_index([ba_state_areas.index.get_level_values(level=0), 'STATE'], inplace=True)
        ba_state_areas = ba_state_areas.reorder_levels(['STATE', 'BA Code'])
        ba_state_areas.sort_index(inplace=True)

        # commercial areas for each BA in each state
        com_ba_areas = ba_state_areas.loc[:, 'All Commercial'].to_frame()

        # total areas by state
        state_com_areas = ba_state_areas.groupby('STATE')['All Commercial'].sum().to_frame()

        # fractions of total state commercial area in each BA
        com_ba_areas['area_frac'] = com_ba_areas.divide(state_com_areas, level=0)

        # multiply state BA fractions by state profiles to get state BA profiles
        com_ba_state_profiles_data = {}
        for idx, row in com_ba_areas.iterrows():
            com_ba_state_profiles_data[idx] = com_hourly_by_state[idx[0]].mul(row['area_frac'])

        com_ba_state_profiles = pd.DataFrame(com_ba_state_profiles_data)

        # convert from kWh to MWh
        com_ba_state_profiles = com_ba_state_profiles / 1e3

        com_ba_profiles = com_ba_state_profiles.T.groupby(level=1).sum().T

        if self.save_processed:
            com_ba_profiles.to_parquet(processed_path)

        return com_ba_profiles
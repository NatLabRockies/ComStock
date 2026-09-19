# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
import argparse
import boto3
import botocore
from joblib import Parallel, delayed
import logging
import numpy as np
import os
import pandas as pd
import random

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

pd.set_option('mode.chained_assignment', None)


def manual_fips_update(df_buildstock):
    """
    Due to discrepancies between Census years, county FIPS in spatial_tract_lookup_published_v8.csv MAY not
    exactly match the counties sampled in ComStock. This function is a manual FIPS update for these counties
    to ensure every sample in ComStock receives the proper geospatial fields in the metadata. The introduction of
    spatial_tract_lookup_published_v7.csv should have fixed these issues but this is yet to be confirmed.

    These counties include (2010 Census): Bedford City County, Shannon County and Wrangell-Petersburg County
    """
    county_fips_map = {
        'G5105150': 'G5100190',         # Bedford City County changed to Bedford County
        'G4601130': 'G4601020',         # Shannon County, SD changed to Oglala Lakota County
        'G0202800': 'G0202750'          # Wrangell County, AK maps to Wrangell City and Borough
    }

    df_buildstock.replace({'county_id': county_fips_map}, inplace=True)

    # The tract column carries the same retired county FIPS prefix and is used as the gisjoin for the
    # geospatial join, so it has to be remapped alongside county_id. Left unmapped, these tracts are absent
    # from the lookup and the county-based resample below finds an empty pool, because county_id has already
    # been rewritten to the new FIPS.
    for old_fips, new_fips in county_fips_map.items():
        is_retired_fips = df_buildstock.loc[:, 'tract'].str.startswith(old_fips)
        df_buildstock.loc[is_retired_fips, 'tract'] = \
            new_fips + df_buildstock.loc[is_retired_fips, 'tract'].str[len(old_fips):]

    return df_buildstock

sqft_value_lkup = {
    '_1000': 1000,
    '1001_3000': 2000,
    '3001_8000': 5500,
    '8001_12000': 10000,
    '12001_30000': 21000,
    '30001_40000': 35000,
    '40001_52000': 46000,
    '52001_64000': 58000,
    '64001_70000': 67000,
    '70001_80000': 75000,
    '80001_100000': 90000,
    '100001_150000': 125000,
    '150001_200000': 175000,
    '200001_400000': 300000,
    '400001_600000': 500000,
    '600001_1mil': 800000,
    'over_1mil': 1100000
}

def the_func(df_buildstock):
    # =========== Determine building size (large vs. not-large) in buildstock file ===========
    sqft = []
    sqft_col = 'building_area'
    for i, row in df_buildstock.iterrows():
        if row[sqft_col] == '_1000':
            sqft.append(1000)
        elif row[sqft_col] == '1001_3000':
            sqft.append(2000)
        elif row[sqft_col] == '3001_8000':
            sqft.append(5500)
        elif row[sqft_col] == '8001_12000':
            sqft.append(10000)
        elif row[sqft_col] == '12001_30000':
            sqft.append(21000)
        elif row[sqft_col] == '30001_40000':
            sqft.append(35000)
        elif row[sqft_col] == '40001_52000':
            sqft.append(46000)
        elif row[sqft_col] == '52001_64000':
            sqft.append(58000)
        elif row[sqft_col] == '64001_70000':
            sqft.append(67000)
        elif row[sqft_col] == '70001_80000':
            sqft.append(75000)
        elif row[sqft_col] == '80001_100000':
            sqft.append(90000)
        elif row[sqft_col] == '100001_150000':
            sqft.append(125000)
        elif row[sqft_col] == '150001_200000':
            sqft.append(175000)
        elif row[sqft_col] == '200001_400000':
            sqft.append(300000)
        elif row[sqft_col] == '400001_600000':
            sqft.append(500000)
        elif row[sqft_col] == '600001_1mil':
            sqft.append(800000)
        elif row[sqft_col] == 'over_1mil':
            sqft.append(1100000)

    df_buildstock['sqft'] = sqft
    df_buildstock.loc[df_buildstock['sqft'] >= 100000, 'building_size'] = 'large'
    df_buildstock.loc[df_buildstock['sqft'] < 100000, 'building_size'] = 'not_large'

    # =========== Update the name of the tract colum ===========
    df_buildstock.loc[:, 'gisjoin'] = df_buildstock.loc[:, 'tract']

    return df_buildstock


def parse_arguments():
    """
    Create argument parser to run assign-tracts-multiprocessing.  Include check to ensure the buildstock file includes a file extension.
    :return argument: Parser arguments to run the file
    """
    parser = argparse.ArgumentParser(description='Sample tracts on a county level to assign geospatial properties')
    parser.add_argument('buildstock_name', type=str, help='Name of buildstock.csv file in "output-buildstocks/intermediate"')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enables verbose debugging outputs')
    argument = parser.parse_args()
    # Check for ".csv" in buildstock name
    if '.csv' not in argument.buildstock_name:
        raise ValueError(f'buildstock_name "{argument.buildstock_name}" is missing the ".csv" file extension.')
    if argument.verbose:
        logger.setLevel('DEBUG')
    return argument


def main():
    args = parse_arguments()
    for arg in vars(args):
        logger.debug(f'{arg} = {getattr(args, arg)}')

    # Create directory if output directory does not exist
    if not os.path.exists(os.path.join('output-buildstocks', 'final')):
        os.makedirs(os.path.join('output-buildstocks', 'final'))
        print("folder '{}' created ".format(os.path.join('output-buildstocks', 'final')))
    # Create directory to download tract data to if it does not already exist
    local_dir = os.path.join('truth_data', 'v01', 'spatial_dists_by_state')
    if not os.path.isdir(local_dir):
        os.makedirs(local_dir)
        print("folder '{}' created ".format(local_dir))


    # Import buildstock.csv
    df_buildstock = pd.read_csv(os.path.join('output-buildstocks', 'intermediate', args.buildstock_name), index_col='Building', na_filter=False)

    # Manually update select FIPS codes due to Census year differences
    df_buildstock = manual_fips_update(df_buildstock)

    # Specify the tract value as the gisjoin value for the spatial lookup
    df_buildstock.loc[:, 'gisjoin'] = df_buildstock.loc[:, 'tract']
    df_geospatial_lkup = pd.read_csv(os.path.join('resources', 'spatial_tract_lookup_table_publish_v10.csv'))
    to_resample = df_buildstock.loc[~df_buildstock.gisjoin.isin(df_geospatial_lkup.nhgis_tract_gisjoin), :]
    print(f'Resampling {to_resample.shape[0]} tracts that are not contained in the geospatial lookup file')

    # Resample required enteries. Replacements are restricted to tracts that are actually in the lookup,
    # otherwise a replacement can itself be unjoinable and the assertion below fails after the run. Where the
    # county contributed no joinable tract to the sample, fall back to the county's tracts in the lookup.
    lkup_tracts = set(df_geospatial_lkup.nhgis_tract_gisjoin)
    lkup_tracts_by_county = df_geospatial_lkup.groupby('nhgis_county_gisjoin')['nhgis_tract_gisjoin'].apply(list)
    resample_lkup = dict()
    for tr in to_resample.gisjoin.unique().tolist():
        samplefrom = sorted({
            gj for gj in df_buildstock.loc[df_buildstock.county_id == tr[:8], 'gisjoin'].tolist()
            if gj in lkup_tracts
        })
        if not samplefrom:
            samplefrom = lkup_tracts_by_county.get(tr[:8], [])
        if not samplefrom:
            raise RuntimeError(
                f'Tract {tr} is not in the geospatial lookup and county {tr[:8]} has no tract in the lookup to '\
                'resample from. A FIPS remap may be missing from manual_fips_update.'
            )
        resample_lkup[tr] = random.sample(samplefrom, 1)[0]
    df_buildstock.loc[
        ~df_buildstock.gisjoin.isin(df_geospatial_lkup.nhgis_tract_gisjoin), 'gisjoin'
    ] = df_buildstock.loc[
        ~df_buildstock.gisjoin.isin(df_geospatial_lkup.nhgis_tract_gisjoin), 'gisjoin'
    ].map(resample_lkup)
    assert(df_buildstock.loc[~df_buildstock.gisjoin.isin(df_geospatial_lkup.nhgis_tract_gisjoin), :].shape[0] == 0)

    # Join the files and ensure no nulls from the merge
    df_results_geospatial = df_buildstock.merge(df_geospatial_lkup, left_on='gisjoin', right_on='nhgis_tract_gisjoin', how='left')
    assert(df_results_geospatial.loc[:, list(df_geospatial_lkup)].isna().sum().sum() == 0)
    df_results_geospatial.drop(['gisjoin'], axis=1, inplace=True)
    df_results_geospatial.index = np.linspace(1, len(df_results_geospatial), len(df_results_geospatial)).astype(int)
    df_results_geospatial.index.name = 'Building'

    # Write to disk
    df_results_geospatial.to_csv(os.path.join('output-buildstocks', 'final', args.buildstock_name), na_rep='NA', index='Building')


if __name__ == '__main__':
    main()

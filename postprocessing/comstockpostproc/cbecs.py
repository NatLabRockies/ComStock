# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
import os

import boto3
import botocore
import logging
import polars as pl

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.s3_utilities_mixin import S3UtilitiesMixin

logger = logging.getLogger(__name__)


class CBECS(NamingMixin, UnitsMixin, S3UtilitiesMixin):
    def __init__(self, cbecs_year, truth_data_version, color_hex=NamingMixin.COLOR_CBECS_2012, weighted_energy_units='tbtu', weighted_utility_units='billion_usd', reload_from_csv=False):
        """
        A class to load and transform CBECS data for export, analysis, and comparison.
        Args:

            cbecs_year (int): The year of CBECS data to retrieve. Currently 2012 and 2018 are available.
            truth_data_version (str): The version/location to retrieve truth/starting data. Truth data
            may change for certain data sources over time, although unlikely for CBECS.
        """

        # Initialize members
        self.year = cbecs_year
        self.truth_data_version = truth_data_version
        self.dataset_name = f'CBECS {self.year}'
        current_dir = os.path.dirname(os.path.abspath(__file__))
        self.truth_data_dir = os.path.join(current_dir, '..', 'truth_data', self.truth_data_version)
        self.resource_dir = os.path.join(current_dir, 'resources')
        self.output_dir = os.path.join(current_dir, '..', 'output', self.dataset_name)
        self.data_file_name = f'CBECS_{self.year}_microdata.csv'
        self.data_codebook_file_name = f'CBECS_{self.year}_microdata_codebook.csv'
        self.building_type_mapping_file_name = f'CBECS_{self.year}_to_comstock_nems_aeo_building_types.csv'
        self.data = None
        self.color = color_hex
        self.weighted_energy_units = weighted_energy_units
        self.weighted_utility_units = weighted_utility_units
        self.s3_client = boto3.client('s3', config=botocore.client.Config(max_pool_connections=50))
        logger.info(f'Creating {self.dataset_name}')

        # Make directories
        for p in [self.truth_data_dir, self.output_dir]:
            if not os.path.exists(p):
                os.makedirs(p)

        # Load and transform data, preserving all columns
        self.download_data()
        if reload_from_csv:
            file_name = f'CBECS wide.csv'
            file_path = os.path.abspath(os.path.join(self.output_dir, file_name))
            if not os.path.exists(file_path):
                raise FileNotFoundError(
                    f'Cannot find {file_path} to reload data, set reload_from_csv=False to create CSV.')
            logger.info(f'Reloading from CSV: {file_path}')
            self.data = pl.read_csv(file_path, infer_schema_length=None)
        else:
            self.load_data()
            self.rename_columns_and_convert_units()
            self.set_column_data_types()
            self.add_dataset_column()
            self.add_comstock_building_type_column()
            self.add_vintage_column()
            self.add_energy_intensity_columns()
            self.add_bill_intensity_columns()
            self.add_energy_rate_columns()
            # Calculate weighted area and energy consumption columns
            self.add_weighted_area_and_energy_columns()
            self.add_primary_system_type_column()

        logger.debug('\nCBECS columns after adding all data')
        for c in self.data.columns:
            logger.debug(c)

        assert isinstance(self.data, pl.DataFrame)
        logging.info(f'Created {self.dataset_name} with {len(self.data)} rows')

        # Cast everything to string, then convert the numeric columns back to
        # numeric. This mirrors the pandas implementation which casts the whole
        # frame to str and then applies pd.to_numeric to columns matching a set
        # of patterns.
        numeric_patterns = [
            self.FLR_AREA,
            self.BLDG_WEIGHT,
            'weight',
            'energy_consumption',
            'calc.weighted',
            'sqft',
            'intensity'
        ]

        cast_exprs = []
        for col in self.data.columns:
            if any(pattern in col for pattern in numeric_patterns):
                cast_exprs.append(pl.col(col).cast(pl.Utf8).cast(pl.Float64, strict=False).alias(col))
            else:
                cast_exprs.append(pl.col(col).cast(pl.Utf8).alias(col))
        self.data = self.data.with_columns(cast_exprs)

        # Convert to a LazyFrame
        self.data = self.data.lazy()
        assert isinstance(self.data, pl.LazyFrame)

    # ------------------------------------------------------------------
    # Small polars helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _to_float(col_name):
        # Convert a column to Float64, coercing non-numeric values (e.g.
        # 'Not Applicable', '.') to null. This mirrors the pandas pattern of
        # replacing the sentinel strings with NaN and then astype('float64').
        return pl.col(col_name).cast(pl.Utf8).str.strip_chars().cast(pl.Float64, strict=False)

    def download_data(self):
        # CBECS microdata
        file_name = f'CBECS_{self.year}_microdata.csv'
        file_path = os.path.join(self.truth_data_dir, file_name)
        if not os.path.exists(file_path):
            s3_file_path = f'truth_data/{self.truth_data_version}/EIA/CBECS/{file_name}'
            self.read_delimited_truth_data_file_from_S3(s3_file_path, ',')

        # CBECS microdata codebook
        file_name = f'CBECS_{self.year}_microdata_codebook.csv'
        file_path = os.path.join(self.truth_data_dir, file_name)
        if not os.path.exists(file_path):
            s3_file_path = f'truth_data/{self.truth_data_version}/EIA/CBECS/{file_name}'
            self.read_delimited_truth_data_file_from_S3(s3_file_path, ',')

        # state region division table
        file_name = f'state_region_division_table.csv'
        file_path = os.path.join(self.truth_data_dir, file_name)
        if not os.path.exists(file_path):
            s3_file_path = f'truth_data/{self.truth_data_version}/EIA/CBECS/{file_name}'
            self.read_delimited_truth_data_file_from_S3(s3_file_path, ',')

        # CBECS HVAC to Comstock System Type Mapping table
        file_name = f'cbecs_{self.year}_w_cstock_hvac.csv'
        file_path = os.path.join(self.truth_data_dir, file_name)
        if not os.path.exists(file_path):
            s3_file_path = f'truth_data/{self.truth_data_version}/EIA/CBECS/{file_name}'
            self.read_delimited_truth_data_file_from_S3(s3_file_path, ',')

    def load_data(self):
        # Load raw microdata and codebook and decode numeric keys to strings using codebook

        # Load microdata
        file_path = os.path.join(self.truth_data_dir, self.data_file_name)
        self.data = pl.read_csv(file_path, null_values=['.'], infer_schema_length=None)
        # Drop fully-null rows to mirror pandas' skip_blank_lines behavior (e.g.
        # a trailing blank line in the source CSV)
        self.data = self.data.filter(~pl.all_horizontal(pl.all().is_null()))

        # Load microdata codebook
        file_path = os.path.join(self.truth_data_dir, self.data_codebook_file_name)
        codebook = pl.read_csv(file_path, infer_schema_length=None)

        # Normalize the codebook name/label columns and compute the final label.
        # Labels that CBECS reused for multiple columns are differentiated by
        # appending the variable name; the first occurrence keeps the plain
        # label (is_first_distinct is True only for that first row).
        codebook = codebook.with_columns(
            pl.col('Variable name').str.strip_chars().alias('_var_name'),
            pl.col('Label').str.strip_chars().alias('_var_label'),
        ).with_columns(
            pl.when(pl.col('_var_label').is_first_distinct())
            .then(pl.col('_var_label'))
            .otherwise(pl.col('_var_label') + pl.lit(' ') + pl.col('_var_name'))
            .alias('_final_label')
        )

        # Make a dict of column names (e.g. PBA) to labels (e.g. Principal building activity)
        var_name_to_label = dict(zip(
            codebook['_var_name'].to_list(),
            codebook['_final_label'].to_list()
        ))

        # Make a dict of labels to a dict of numeric enumerations -> strings for
        # non-numeric variables. The 'key=value|key=value' format is exploded
        # into long form and grouped by label rather than iterating row-by-row.
        enum_long = (
            codebook
            .select('_final_label', 'Values/Format codes')
            .drop_nulls('Values/Format codes')
            .with_columns(pl.col('Values/Format codes').str.split('|').alias('_seg'))
            .explode('_seg')
            .filter(pl.col('_seg').str.contains('=', literal=True))
            .with_columns(pl.col('_seg').str.split_exact('=', 1).alias('_kv'))
            .with_columns(
                pl.col('_kv').struct.field('field_0').alias('_enum_key'),
                pl.col('_kv').struct.field('field_1').str.strip_chars().alias('_enum_val'),
            )
            .group_by('_final_label', maintain_order=True)
            .agg(pl.col('_enum_key'), pl.col('_enum_val'))
        )
        var_label_to_enums = {
            label: dict(zip(keys, vals))
            for label, keys, vals in zip(
                enum_long['_final_label'].to_list(),
                enum_long['_enum_key'].to_list(),
                enum_long['_enum_val'].to_list(),
            )
        }

        # Rename the columns (only those present in the microdata)
        rename_map = {name: label for name, label in var_name_to_label.items() if name in self.data.columns}
        self.data = self.data.rename(rename_map)

        # Double-check for duplicate columns; there should be none
        seen = set()
        drop_cols = []
        for col in self.data.columns:
            if col in seen:
                logger.warning(f'Dropped column with duplicate label: {col}')
                drop_cols.append(col)
            seen.add(col)
        if drop_cols:
            self.data = self.data.drop(drop_cols)

        # Decode the column values using the codebook enumerations. This mirrors
        # the pandas decode_variable logic:
        #   - null values become 'Missing'
        #   - numeric keys are looked up as their integer-string representation
        #   - unmapped values are left unchanged
        decode_exprs = []
        for col_name in self.data.columns:
            if col_name in var_label_to_enums:
                decoder_map = var_label_to_enums[col_name]
                dtype = self.data.schema[col_name]
                if dtype.is_numeric():
                    key = (
                        pl.when(pl.col(col_name).is_null())
                        .then(pl.lit('Missing'))
                        .otherwise(pl.col(col_name).cast(pl.Int64, strict=False).cast(pl.Utf8))
                    )
                else:
                    key = (
                        pl.when(pl.col(col_name).is_null())
                        .then(pl.lit('Missing'))
                        .otherwise(pl.col(col_name).cast(pl.Utf8))
                    )
                decode_exprs.append(key.replace(decoder_map).alias(col_name))
        if decode_exprs:
            self.data = self.data.with_columns(decode_exprs)

    def rename_columns_and_convert_units(self):
        column_map = {
            # Building characteristics
            'Building identifier': self.BLDG_ID,  # CBECS 2012
            'Public use file building identifier': self.BLDG_ID,  # CBECS 2018
            'Census region': self.CEN_REG,
            'Census division': self.CEN_DIV,
            'Square footage': self.FLR_AREA,
            'Square footage category': self.FLR_AREA_CAT,
            'More specific building activity': self.CBECS_BLDG_TYPE,
            'Year of construction': self.YEAR_BUILT,
            'Final full sample building weight': self.BLDG_WEIGHT,  # CBECS 2012
            'Nonresponse Adjusted Weight': self.BLDG_WEIGHT,  # CBECS 2018
            'Annual major fuel consumption (thous Btu)': self.ANN_TOT_ENGY_KBTU,
            'Annual electricity consumption (thous Btu)': self.ANN_TOT_ELEC_KBTU,
            'Annual natural gas consumption (thous Btu)': self.ANN_TOT_GAS_KBTU,
            'Annual fuel oil consumption (thous Btu)': self.ANN_TOT_FUELOIL_KBTU,
            'Annual propane consumption (thous Btu)': self.ANN_TOT_PROPANE_KBTU,
            'Annual district heat consumption (thous Btu)': self.ANN_TOT_DISTHTG_KBTU,
            # End use energy - electricity
            'Electricity heating use (thous Btu)': self.ANN_ELEC_HEAT_KBTU,
            'Electricity cooling use (thous Btu)': self.ANN_ELEC_COOL_KBTU,
            'Electricity ventilation use (thous Btu)': self.ANN_ELEC_FANS_KBTU,
            'Electricity water heating use (thous Btu)': self.ANN_ELEC_SWH_KBTU,
            'Electricity lighting use (thous Btu)': self.ANN_ELEC_INTLTG_KBTU,
            'Electricity refrigeration use (thous Btu)': self.ANN_ELEC_REFRIG_KBTU,
            # End use energy - natural gas
            'Natural gas heating use (thous Btu)': self.ANN_GAS_HEAT_KBTU,
            'Natural gas cooling use (thous Btu)': self.ANN_GAS_COOL_KBTU,
            'Natural gas water heating use (thous Btu)': self.ANN_GAS_SWH_KBTU,
            # End use energy - propane
            'Propane heating use (thous Btu)': self.ANN_PROPANE_HEAT_KBTU,
            'Propane water heating use (thous Btu)': self.ANN_PROPANE_SWH_KBTU,
            # End use energy - fuel oil
            'Fuel oil heating use (thous Btu)': self.ANN_FUELOIL_HEAT_KBTU,
            'Fuel oil water heating use (thous Btu)': self.ANN_FUELOIL_SWH_KBTU,
            # End use energy - district heating
            'District heat heating use (thous Btu)': self.ANN_DISTHTG_HEAT_KBTU,
            'District heat cooling use (thous Btu)': self.ANN_DISTHTG_COOL_KBTU,
            'District heat water heating use (thous Btu)': self.ANN_DISTHTG_SWH_KBTU,
            # Utility bills
            'Annual electricity expenditures ($)': self.UTIL_BILL_ELEC,
            'Annual natural gas expenditures ($)': self.UTIL_BILL_GAS,
            'Annual fuel oil expenditures ($)': self.UTIL_BILL_FUEL_OIL
        }

        rename_map = {old: new for old, new in column_map.items() if old in self.data.columns}
        self.data = self.data.rename(rename_map)

        # Combine some CBECS columns to match ComStock
        combo_cols = [
            # End use energy - electricity interior equipment
            [['Electricity cooking use (thous Btu)',
            'Electricity office equipment use (thous Btu)',
            'Electricity computing use (thous Btu)',
            'Electricity miscellaneous use (thous Btu)'], self.ANN_ELEC_INTEQUIP_KBTU],
            # End use energy - natural gas interior equipment
            [['Natural gas cooking use (thous Btu)',
            'Natural gas miscellaneous use (thous Btu)'], self.ANN_GAS_INTEQUIP_KBTU],
            # End use energy - propane interior equipment
            [['Propane cooking use (thous Btu)',
            'Propane miscellaneous use (thous Btu)'], self.ANN_PROPANE_INTEQUIP_KBTU],
            # End use energy - fuel oil interior equipment
            [['Fuel oil cooking use (thous Btu)',
            'Fuel oil miscellaneous use (thous Btu)'], self.ANN_FUELOIL_INTEQUIP_KBTU],
            # End use energy - district heating interior equipment
            [['District heat cooking use (thous Btu)',
            'District heat miscellaneous use (thous Btu)'], self.ANN_DISTHTG_INTEQUIP_KBTU]
        ]
        combo_exprs = []
        source_cast_exprs = []
        seen_sources = set()
        for cols, new_col_name in combo_cols:
            found_cols = []
            for col in cols:
                if col not in self.data.columns:
                    logger.warning(f'Missing energy column {col}, will not be included in {new_col_name}')
                    continue
                found_cols.append(col)
                # Cast the source column to float in place (mirrors pandas)
                if col not in seen_sources:
                    source_cast_exprs.append(self._to_float(col).alias(col))
                    seen_sources.add(col)
            if found_cols:
                combo_exprs.append(pl.sum_horizontal([self._to_float(c) for c in found_cols]).alias(new_col_name))
            else:
                combo_exprs.append(pl.lit(0.0).alias(new_col_name))
        if source_cast_exprs:
            self.data = self.data.with_columns(source_cast_exprs)
        if combo_exprs:
            self.data = self.data.with_columns(combo_exprs)

        # Convert all energy columns from base CBECS kBtu to kWh
        conv_exprs = []
        base_cbecs_units = 'kbtu'
        for col in (self.COLS_TOT_ANN_ENGY + self.COLS_ENDUSE_ANN_ENGY):
            # Skip end-use columns that aren't part of CBECS
            if col not in self.data.columns:
                continue
            # Convert to match units in the column name
            target_units = self.units_from_col_name(col)
            conv_fact = self.conv_fact(base_cbecs_units, target_units)
            conv_exprs.append((self._to_float(col) * conv_fact).alias(col))
        if conv_exprs:
            self.data = self.data.with_columns(conv_exprs)

    def set_column_data_types(self):
        # Ensure the total annual energy columns are numeric
        cast_exprs = []
        for col in self.COLS_TOT_ANN_ENGY:
            if col in self.data.columns:
                cast_exprs.append(self._to_float(col).alias(col))
        if cast_exprs:
            self.data = self.data.with_columns(cast_exprs)

    def add_dataset_column(self):
        self.data = self.data.with_columns(pl.lit(self.dataset_name).alias(self.DATASET))

    def add_energy_intensity_columns(self):
        # Ensure the floor area is numeric before dividing
        add_null_exprs = []
        for engy_col in (self.COLS_TOT_ANN_ENGY + self.COLS_ENDUSE_ANN_ENGY):
            # Put in null for end-use columns that aren't part of CBECS
            if engy_col not in self.data.columns:
                add_null_exprs.append(pl.lit(None, dtype=pl.Float64).alias(engy_col))
        if add_null_exprs:
            self.data = self.data.with_columns(add_null_exprs)

        # Create EUI column for each annual energy column
        eui_exprs = []
        area = self._to_float(self.FLR_AREA)
        for engy_col in (self.COLS_TOT_ANN_ENGY + self.COLS_ENDUSE_ANN_ENGY):
            eui_col = self.col_name_to_eui(engy_col)
            eui_exprs.append((self._to_float(engy_col) / area).alias(eui_col))
        if eui_exprs:
            self.data = self.data.with_columns(eui_exprs)

    def add_bill_intensity_columns(self):
        # Create bill per area column for each annual utility bill column
        add_null_exprs = []
        for bill_col in self.COLS_UTIL_BILLS:
            # Put in null for bill columns that aren't part of CBECS
            if bill_col not in self.data.columns:
                add_null_exprs.append(pl.lit(None, dtype=pl.Float64).alias(bill_col))
        if add_null_exprs:
            self.data = self.data.with_columns(add_null_exprs)

        # Cast the bill columns to float in place (mirrors pandas), then create
        # the per-area intensity columns
        bill_cast_exprs = []
        per_area_exprs = []
        area = self._to_float(self.FLR_AREA)
        for bill_col in self.COLS_UTIL_BILLS:
            bill_cast_exprs.append(self._to_float(bill_col).alias(bill_col))
            per_area_col = self.col_name_to_area_intensity(bill_col)
            per_area_exprs.append((self._to_float(bill_col) / area).alias(per_area_col))
        if bill_cast_exprs:
            self.data = self.data.with_columns(bill_cast_exprs)
        if per_area_exprs:
            self.data = self.data.with_columns(per_area_exprs)

    def add_energy_rate_columns(self):
        # Create energy rate column for each annual utility bill column
        rate_exprs = []
        for bill_col in self.COLS_UTIL_BILLS:
            # Get the corresponding energy consumption column
            bill_to_engy_col = {
                self.UTIL_BILL_ELEC: self.ANN_TOT_ELEC_KBTU,
                self.UTIL_BILL_GAS: self.ANN_TOT_GAS_KBTU,
                self.UTIL_BILL_FUEL_OIL: None,
                self.UTIL_BILL_PROPANE: None
            }
            # Only create rate columns for fuels with bills
            engy_col = bill_to_engy_col[bill_col]
            if not engy_col:
                continue
            # Divide bill by consumption to create rate
            rate_col = self.col_name_to_energy_rate(bill_col)
            rate_exprs.append((self._to_float(bill_col) / self._to_float(engy_col)).alias(rate_col))
        if rate_exprs:
            self.data = self.data.with_columns(rate_exprs)

    def add_comstock_building_type_column(self):
        # Add the ComStock building type for each row of CBECS

        # Load the building type mapping file
        file_path = os.path.join(self.resource_dir, self.building_type_mapping_file_name)
        bldg_type_map = pl.read_csv(file_path, infer_schema_length=None)

        # Build a dict from CBECS building activity -> intermediate ComStock building type
        inter_map = dict(zip(
            bldg_type_map['CBECS More specific building activity'].to_list(),
            bldg_type_map['ComStock Intermediate Building Type'].to_list()
        ))

        # Look up the intermediate comstock building type
        inter = pl.col(self.CBECS_BLDG_TYPE).replace_strict(inter_map, default=None)

        # Recode the number of floors, handling both CBECS 2012 and 2018 enumerations
        nfloor_str = pl.col('Number of floors').cast(pl.Utf8)
        nfloor = (
            pl.when(nfloor_str == '15 to 25').then(pl.lit(15.0))      # CBECS 2012
            .when(nfloor_str == 'More than 25').then(pl.lit(26.0))    # CBECS 2012
            .when(nfloor_str == '10 to 14').then(pl.lit(10.0))        # CBECS 2018
            .when(nfloor_str == '15 or more').then(pl.lit(15.0))      # CBECS 2018
            .otherwise(pl.col('Number of floors').cast(pl.Utf8).str.strip_chars().cast(pl.Float64, strict=False))
        )

        sqft = self._to_float(self.FLR_AREA)

        # Assign size category to offices
        office_type = (
            pl.when(sqft < 25_000)
                .then(pl.when(nfloor <= 3).then(pl.lit('SmallOffice')).otherwise(pl.lit('MediumOffice')))
            .when((sqft >= 25_000) & (sqft < 150_000))
                .then(pl.when(nfloor <= 5).then(pl.lit('MediumOffice')).otherwise(pl.lit('LargeOffice')))
            .when(sqft >= 150_000)
                .then(pl.lit('LargeOffice'))
            .otherwise(pl.lit(None, dtype=pl.Utf8))
        )

        cstock_bldg_type = (
            pl.when(inter == 'Office')
            .then(office_type)
            .otherwise(inter)
        )

        self.data = self.data.with_columns(cstock_bldg_type.alias(self.BLDG_TYPE))

    def add_aeo_nems_building_type_column(self):
        # Add the AEO and NEMS building type for each row of CBECS

        # Load the building type mapping file
        file_path = os.path.join(self.resource_dir, self.building_type_mapping_file_name)
        bldg_type_map = pl.read_csv(file_path, infer_schema_length=None)

        aeo_map = dict(zip(
            bldg_type_map['CBECS More specific building activity'].to_list(),
            bldg_type_map['NEMS and AEO Intermediate Building Type'].to_list()
        ))

        inter = pl.col(self.CBECS_BLDG_TYPE).replace_strict(aeo_map, default=None)
        sqft = self._to_float(self.FLR_AREA)

        office_type = (
            pl.when(sqft <= 50_000)
            .then(pl.lit('Office - Small'))
            .otherwise(pl.lit('Office - Large'))
        )

        aeo_bldg_type = (
            pl.when(inter == 'Office')
            .then(office_type)
            .otherwise(inter)
        )

        self.data = self.data.with_columns(aeo_bldg_type.alias(self.AEO_BLDG_TYPE))

    def add_vintage_column(self):
        # Adds decadal vintage bins used in CBECS 2018

        if self.YEAR_BUILT in self.data.columns:
            year_str = pl.col(self.YEAR_BUILT).cast(pl.Utf8)
            year_num = pl.col(self.YEAR_BUILT).cast(pl.Utf8).str.strip_chars().cast(pl.Float64, strict=False)
            vintage = (
                pl.when(year_str == 'Before 1946').then(pl.lit('Before 1946'))
                .when((year_num > 1946) & (year_num < 1960)).then(pl.lit('1946 to 1959'))
                .when(year_num < 1970).then(pl.lit('1960 to 1969'))
                .when(year_num < 1980).then(pl.lit('1970 to 1979'))
                .when(year_num < 1990).then(pl.lit('1980 to 1989'))
                .when(year_num < 2000).then(pl.lit('1990 to 1999'))
                .when(year_num < 2013).then(pl.lit('2000 to 2012'))
                .when(year_num < 2019).then(pl.lit('2013 to 2018'))
                .otherwise(pl.lit('2019 or newer'))
            )
            self.data = self.data.with_columns(vintage.alias(self.VINTAGE))
        else:
            # Use the vintage bins already in CBECS
            self.data = self.data.with_columns(
                pl.col('Year of construction category').alias(self.VINTAGE)
            )

    def add_weighted_area_and_energy_columns(self):
        weight = self._to_float(self.BLDG_WEIGHT)

        # Area - ensure the column is numeric then create weighted column
        new_area_col = self.col_name_to_weighted(self.FLR_AREA)
        area = self._to_float(self.FLR_AREA)
        wtd_exprs = [
            area.alias(self.FLR_AREA),
            (area * weight).alias(new_area_col)
        ]

        # Energy
        for col in (self.COLS_TOT_ANN_ENGY + self.COLS_ENDUSE_ANN_ENGY):
            # Skip end-use columns that aren't part of CBECS
            if col not in self.data.columns:
                continue
            new_col = self.col_name_to_weighted(col, self.weighted_energy_units)

            # Weight and convert to the target units (e.g. TBtu)
            old_units = self.units_from_col_name(col)
            new_units = self.weighted_energy_units
            conv_fact = self.conv_fact(old_units, new_units)
            wtd_exprs.append((self._to_float(col) * weight * conv_fact).alias(new_col))

        self.data = self.data.with_columns(wtd_exprs)

    def add_primary_system_type_column(self):
        # CBECS HVAC Data
        file_name = f'cbecs_{self.year}_w_cstock_hvac_v3.csv'
        file_path = os.path.join(self.truth_data_dir, file_name)

        # Check if file exists
        if not os.path.exists(file_path):
            logger.info(f"File {file_name} does not exist. Skipping...")
            return

        # Read CSV file into a DataFrame
        hvac_df = pl.read_csv(file_path, infer_schema_length=None)

        # Select 'PUBID' and 'cstock_sys_type' columns and rename to match
        hvac_df = hvac_df.select(['PUBID', 'cstock_sys_type']).rename({
            'PUBID': self.BLDG_ID,
            'cstock_sys_type': self.HVAC_SYS
        })

        # Align the join key dtypes (bldg_id is an integer identifier)
        hvac_df = hvac_df.with_columns(pl.col(self.BLDG_ID).cast(pl.Int64, strict=False))
        self.data = self.data.with_columns(
            pl.col(self.BLDG_ID).cast(pl.Utf8).str.strip_chars().cast(pl.Int64, strict=False)
        )

        # Merge HVAC data with existing data
        self.data = self.data.join(hvac_df, on=self.BLDG_ID, how='left')

    def export_to_csv_wide(self):
        # Exports comstock data to CSV in wide format

        file_name = f'CBECS wide.csv'
        file_path = os.path.join(self.output_dir, file_name)
        try:
            self.data.sink_csv(file_path)
        except pl.exceptions.InvalidOperationError:
            logger.warning('Warning - sink_csv not supported for metadata write in current polars version')
            logger.warning('Falling back to .collect.write_csv')
            self.data.collect().write_csv(file_path)

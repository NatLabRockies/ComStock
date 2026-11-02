"""
Query templates and builders for ComStock data extraction from Athena.

This module provides SQL query templates and builder functions to construct
Athena queries for various ComStock analysis needs.
"""

import logging
from typing import List, Optional, Union

logger = logging.getLogger(__name__)


class ComStockQueryBuilder:
    """
    Builder class for creating SQL queries to extract ComStock data from Athena.

    This class provides templated queries that can be customized with parameters
    for different analysis needs while maintaining consistent query structure.
    """

    def __init__(self, athena_table_name: str):
        """
        Initialize the query builder with the base Athena table name.

        Args:
            athena_table_name: Base name of the Athena table (without _timeseries or _baseline suffix)
        """
        self.athena_table_name = athena_table_name
        self.timeseries_table = f"{athena_table_name}_timeseries"
        self.baseline_table = f"{athena_table_name}_baseline"

    #TODO: this method has not yet been validated, and should be prior to use.
    def get_monthly_energy_consumption_query(self,
        upgrade_ids: Optional[List[Union[int, str]]] = None,
        states: Optional[List[str]] = None,
        building_types: Optional[List[str]] = None) -> str:
        """
        Build query for monthly natural gas and electricity consumption by state and building type.

        Args:
            upgrade_ids: List of upgrade IDs to filter on (optional)
            states: List of state IDs to filter on (optional)
            building_types: List of building types to filter on (optional)

        Returns:
            SQL query string

        """

        # Build WHERE clause conditions
        where_conditions = ['"build_existing_model.building_type" IS NOT NULL']

        if upgrade_ids:
            upgrade_list = ', '.join([f'"{uid}"' for uid in upgrade_ids])
            where_conditions.append(f'"upgrade" IN ({upgrade_list})')

        if states:
            state_list = ', '.join([f'"{state}"' for state in states])
            where_conditions.append(f'SUBSTRING("build_existing_model.county_id", 2, 2) IN ({state_list})')

        if building_types:
            btype_list = ', '.join([f'"{bt}"' for bt in building_types])
            where_conditions.append(f'"build_existing_model.create_custom_building_from_spec_bldg_type_a" IN ({btype_list})')

        where_clause = ' AND '.join(where_conditions)

        query = f"""
            SELECT
                "upgrade",
                "month",
                "state_id",
                "building_type",
                sum("total_site_gas_kbtu") AS "total_site_gas_kbtu",
                sum("total_site_electricity_kwh") AS "total_site_electricity_kwh"
            FROM
            (
                SELECT
                    EXTRACT(MONTH from "time") as "month",
                    SUBSTRING("build_existing_model.county_id", 2, 2) AS "state_id",
                    "build_existing_model.create_custom_building_from_spec_bldg_type_a" as "building_type",
                    "upgrade",
                    "total_site_gas_kbtu",
                    "total_site_electricity_kwh"
                FROM
                    "{self.timeseries_table}"
                JOIN "{self.baseline_table}"
                    ON "{self.timeseries_table}"."building_id" = "{self.baseline_table}"."building_id"
                WHERE {where_clause}
            )
            GROUP BY
                "upgrade",
                "month",
                "state_id",
                "building_type"
        """

        return query.strip()

    def get_timeseries_aggregation_query(
        self,
        upgrade_id: Union[int, str],
        enduses: List[str],
        weight_view_table: str,
        group_by: Optional[List[str]] = None,
        restrictions: List[tuple] = None,
        timestamp_grouping: str = 'hour',
        building_ids: Optional[List[int]] = None,
        include_sample_stats: bool = True,
        include_area_normalized_cols: bool = False) -> str:
        """
        Build query for timeseries data aggregation similar to buildstock query functionality.

        This matches the pattern from working buildstock queries that join timeseries data
        with a weight view table for proper weighting and aggregation.

        Automatically detects if the timeseries table is partitioned by state based on naming conventions:
        - Tables with 'ts_by_state' in the name are treated as state-partitioned
        - Tables with '_timeseries' in the name (without 'ts_by_state') are treated as non-partitioned
        - Other naming patterns assume no partitioning with a warning to the user regarding this assumption.
        TODO: Improve this in the future to check for partitioning directly from Athena metadata if possible.

        Args:
            upgrade_id: Upgrade ID to filter on
            enduses: List of end use columns to select
            weight_view_table: Name of the weight view table (required - e.g., 'rtuadv_v11_md_agg_national_by_state_vu' or 'rtuadv_v11_md_agg_national_by_county_vu')
            group_by: Additional columns to group by (e.g., ['build_existing_model.building_type'])
            restrictions: List of (column, values) tuples for filtering
            timestamp_grouping: How to group timestamps ('hour', 'day', 'month')
            building_ids: Specific building IDs to filter on (optional)
            include_sample_stats: Whether to include sample_count, units_count, rows_per_sample
            include_area_normalized_cols: Whether to include weighted area and kwh_weighted columns for AMI comparison

        Returns:
            SQL query string

        """

        # Weight view table is required - cannot auto-assign without knowing state vs county aggregation
        if weight_view_table is None:
            raise ValueError("weight_view_table parameter is required. Cannot auto-assign without knowing geographic aggregation level (state vs county). "
                           "Please provide the full weight view table name (e.g., 'your_dataset_md_agg_national_by_state_vu' or 'your_dataset_md_agg_national_by_county_vu')")

        # Auto-detect if timeseries is partitioned by state based on naming conventions
        table_name_lower = self.timeseries_table.lower()
        if 'ts_by_state' in table_name_lower:
            timeseries_partitioned_by_state = True
            logger.info(f"Detected state-partitioned timeseries table: {self.timeseries_table}. "
                       "Query will include state partition filter so timeseries files for a building ID are not double counted.")
        elif '_timeseries' in table_name_lower:
            timeseries_partitioned_by_state = False
            logger.info(f"Detected standard non-partitioned timeseries table: {self.timeseries_table}")
        else:
            timeseries_partitioned_by_state = False
            logger.warning(f"Timeseries table name '{self.timeseries_table}' does not match expected patterns ('ts_by_state' or '_timeseries'). "
                          "Assuming no state partitioning. If the table is actually partitioned by state, building IDs may be double-counted. "
                          "Please use standard naming conventions: 'dataset_ts_by_state' for partitioned or 'dataset_timeseries' for non-partitioned tables.")

        # Build timestamp grouping with date_trunc and time adjustment
        time_group = '1'
        if timestamp_grouping == 'hour':
            time_select = f"date_trunc('hour', date_add('second', -900, {self.timeseries_table}.time)) AS time"
        elif timestamp_grouping == 'day':
            time_select = f"date_trunc('day', {self.timeseries_table}.time) AS time"
        elif timestamp_grouping == 'month':
            time_select = f"date_trunc('month', {self.timeseries_table}.time) AS time"
        else:
            time_select = f"{self.timeseries_table}.time AS time"

        # Build SELECT clause with sample statistics
        select_clauses = [time_select]

        # Add group_by columns to SELECT (excluding 'time' which is already handled)
        if group_by:
            for col in group_by:
                if col != 'time':
                    select_clauses.append(f'{weight_view_table}."{col}"')

        if include_sample_stats:
            select_clauses.extend([
                f"count(distinct({self.timeseries_table}.building_id)) AS sample_count",
                f"(count(distinct({self.timeseries_table}.building_id)) * sum({weight_view_table}.weight)) / sum(1) AS units_count",
                f"sum(1) / count(distinct({self.timeseries_table}.building_id)) AS rows_per_sample"
            ])

        # Add weighted area if requested (for AMI comparison)
        if include_area_normalized_cols:
            weighted_area = f'sum({weight_view_table}."in.sqft" * {weight_view_table}.weight) AS weighted_sqft'
            select_clauses.append(weighted_area)

        # Build weighted enduse aggregations
        for enduse in enduses:
            weighted_sum = f"sum({self.timeseries_table}.{enduse} * {weight_view_table}.weight) AS {enduse}"
            select_clauses.append(weighted_sum)

            # Add kwh_per_sf columns if requested (for AMI comparison - normalized by weighted area)
            # Note: Building area is per building, but appears in multiple timestep rows when joined.
            # The sum() counts each building's area once per timestep. Divide by rows_per_sample to correct.
            #
            # Example: 4 buildings (each 10k sqft), 15-min data aggregated to hourly (4 timesteps):
            #   - Each building contributes 4 rows (one per 15-min interval)
            #   - weighted_energy_sum: 100 kWh (energy varies per timestep, summed across all 16 rows)
            #   - weighted_area_sum: 160k sqft (same 10k per building repeated 4 times: 4 buildings × 10k × 4 timesteps)
            #   - rows_per_sample: 16 total rows / 4 distinct buildings = 4 timesteps/building
            #   - Corrected area: 160k / 4 = 40k sqft (removes timestep duplication)
            #   - Result: 100 kWh / 40k sqft = 0.0025 kWh/sqft
            if include_area_normalized_cols and enduse.endswith('_kwh'):
                # Build the formula in parts for clarity
                weighted_energy_sum = f"sum({self.timeseries_table}.{enduse} * {weight_view_table}.weight)"
                weighted_area_sum = f"sum({weight_view_table}.\"in.sqft\" * {weight_view_table}.weight)"
                rows_per_sample = f"(sum(1) / count(distinct({self.timeseries_table}.building_id)))"
                corrected_area = f"({weighted_area_sum} / {rows_per_sample})"

                kwh_per_sf = f"{weighted_energy_sum} / {corrected_area} AS {enduse.replace('_kwh', '_kwh_per_sf')}"
                select_clauses.append(kwh_per_sf)

        select_clause = ',\n    '.join(select_clauses)

        # Build WHERE clause - join conditions first, then filters
        where_conditions = [
            f'{weight_view_table}."bldg_id" = {self.timeseries_table}.building_id',
            f'{weight_view_table}.upgrade = {self.timeseries_table}.upgrade',
            f'{weight_view_table}.upgrade = {upgrade_id}'
        ]

        # Add state partition filter if timeseries is partitioned by state (enables partition pruning)
        # When partitioned by state, each building's timeseries data is duplicated across each state
        # it is apportioned to. To avoid double counting, we filter to only the state matching the weight view.
        if timeseries_partitioned_by_state:
            where_conditions.append(f'{weight_view_table}.state = {self.timeseries_table}.state')

        if building_ids:
            bldg_list = ', '.join([str(bid) for bid in building_ids])
            where_conditions.append(f'{weight_view_table}."bldg_id" IN ({bldg_list})')

        # Handle restrictions - these are typically filters on the weight view table
        if restrictions:
            for column, values in restrictions:
                # Determine if this is a numeric column that shouldn't be quoted
                numeric_columns = ['bldg_id', 'building_id', 'upgrade', 'upgrade_id']
                is_numeric = column in numeric_columns

                if isinstance(values, (list, tuple)):
                    if len(values) == 1:
                        if is_numeric:
                            where_conditions.append(f'{weight_view_table}."{column}" = {values[0]}')
                        else:
                            where_conditions.append(f'{weight_view_table}."{column}" = \'{values[0]}\'')
                    else:
                        if is_numeric:
                            value_list = ', '.join([str(v) for v in values])
                        else:
                            value_list = ', '.join([f"'{v}'" for v in values])
                        where_conditions.append(f'{weight_view_table}."{column}" IN ({value_list})')
                else:
                    if is_numeric:
                        where_conditions.append(f'{weight_view_table}."{column}" = {values}')
                    else:
                        where_conditions.append(f'{weight_view_table}."{column}" = \'{values}\'')

        where_clause = ' AND '.join(where_conditions)

        # Build GROUP BY clause - use column positions based on SELECT order
        group_by_positions = [time_group]  # Time is always position 1
        if group_by:
            # Add positions for additional group_by columns (excluding 'time')
            position = 2  # Start after time
            for col in group_by:
                if col != 'time':
                    group_by_positions.append(str(position))
                    position += 1

        group_by_clause = ', '.join(group_by_positions)

        # Build the query using FROM clause with comma-separated tables
        query = f"""SELECT {select_clause}
        FROM {weight_view_table}, {self.timeseries_table}
        WHERE {where_clause}
        GROUP BY {group_by_clause}
        ORDER BY {group_by_clause}"""

        return query

    def get_applicability_query(self,
        upgrade_ids: List[Union[int, str]],
        state: Optional[Union[str, List[str]]] = None,
        county: Optional[Union[str, List[str]]] = None,
        columns: Optional[List[str]] = None,
        weight_view_table: Optional[str] = None) -> str:
        """
        Build query to get applicable buildings and their characteristics from the weight view.

        Args:
            upgrade_ids: List of upgrade IDs to filter on
            state: State abbreviation(s) to filter on (optional, can be single string or list)
            county: County GISJOIN(s) to filter on (optional, can be single string or list)
            columns: Specific columns to select (optional, defaults to common applicability columns)
            weight_view_table: Name of the weight view table (optional, uses default naming)

        Returns:
            SQL query string

        """

        # If no weight view table provided, construct name based on geographic level
        if weight_view_table is None:
            if county is not None:
                weight_view_table = f"{self.athena_table_name}_md_agg_national_by_county_vu"
            else:
                weight_view_table = f"{self.athena_table_name}_md_agg_national_by_state_vu"

        # Default columns for applicability queries
        if columns is None:
            # Choose geographic column based on which filter is being used
            geo_column = '"in.nhgis_county_gisjoin"' if county else '"in.state"'
            columns = [
                'dataset',
                geo_column,
                'bldg_id',
                'upgrade',
                'applicability'
            ]

        # Build SELECT clause
        select_clause = ',\n            '.join(columns)

        # Build WHERE clause
        where_conditions = []

        # Filter by upgrade IDs
        if len(upgrade_ids) == 1:
            where_conditions.append(f'upgrade = {upgrade_ids[0]}')
        else:
            upgrade_list = ','.join(map(str, upgrade_ids))
            where_conditions.append(f'upgrade IN ({upgrade_list})')

        # Filter by applicability
        where_conditions.append('applicability = true')

        # Filter by geographic location (state or county) - support single values or lists
        if state:
            if isinstance(state, str):
                where_conditions.append(f'"in.state" = \'{state}\'')
            elif isinstance(state, (list, tuple)):
                if len(state) == 1:
                    where_conditions.append(f'"in.state" = \'{state[0]}\'')
                else:
                    state_list = "', '".join(state)
                    where_conditions.append(f'"in.state" IN (\'{state_list}\')')
        elif county:
            if isinstance(county, str):
                where_conditions.append(f'"in.nhgis_county_gisjoin" = \'{county}\'')
            elif isinstance(county, (list, tuple)):
                if len(county) == 1:
                    where_conditions.append(f'"in.nhgis_county_gisjoin" = \'{county[0]}\'')
                else:
                    county_list = "', '".join(county)
                    where_conditions.append(f'"in.nhgis_county_gisjoin" IN (\'{county_list}\')')

        where_clause = ' AND '.join(where_conditions)

        query = f"""
        SELECT DISTINCT
            {select_clause}
        FROM {weight_view_table}
        WHERE {where_clause}
        ORDER BY bldg_id
        """

        return query.strip()
# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
import os
import re
import logging
import numpy as np
import pandas as pd
import matplotlib
import matplotlib.pyplot as plt
from matplotlib import ticker
import plotly.express as px
import plotly.io as pio
import seaborn as sns
import plotly.graph_objects as go
import matplotlib.colors as mcolors
from plotly.subplots import make_subplots
from comstockpostproc.rse_utils_mixin import rse_by_group_total


matplotlib.use('Agg')
logger = logging.getLogger(__name__)

# color setting for savings distributions
color_violin = "#EFF2F1"
color_interquartile = "#6A9AC3"

# Kaleido v1 renders through a real Chrome process launched by choreographer, and
# plotly starts and tears down one browser per write_image() call. That teardown is
# unreliable on Windows: it raises "Couldn't close or kill browser subprocess" from
# Kaleido's __aexit__, which discards the already-rendered bytes and aborts the run.
# Queueing figures and exporting them through pio.write_images() reuses one browser
# for the whole batch, so there are far fewer teardowns to fail.
# The batch is capped so a long plotting loop does not hold many figures in memory.
FIGURE_BATCH_SIZE = 8


class PlottingMixin():

    def queue_figure(self, fig, file_path, scale=None):
        """Queue a figure for batched export instead of writing it immediately.

        Call flush_figures() once the enclosing plot method has queued everything it
        intends to write. Queued figures are also flushed automatically whenever the
        batch reaches FIGURE_BATCH_SIZE.
        """
        if getattr(self, '_figure_queue', None) is None:
            self._figure_queue = []
        self._figure_queue.append((fig, file_path, scale))
        if len(self._figure_queue) >= FIGURE_BATCH_SIZE:
            self.flush_figures()

    def flush_figures(self):
        """Write every queued figure, preferring a single batched export.

        Falls back to writing figures one at a time if the batch fails or if plotly is
        too old to provide write_images. A figure that still cannot be written is
        logged and skipped rather than aborting a plotting run that may have hours of
        work behind it.
        """
        queued = getattr(self, '_figure_queue', None)
        if not queued:
            return
        # Clear first so a failure part way through cannot re-write earlier figures
        self._figure_queue = []

        figs = [fig for fig, _, _ in queued]
        paths = [path for _, path, _ in queued]
        scales = [scale for _, _, scale in queued]

        if hasattr(pio, 'write_images'):
            try:
                pio.write_images(figs, paths, scale=scales)
                return
            except Exception as e:
                logger.warning(
                    f'Batched export of {len(figs)} figures failed ({type(e).__name__}: {e}). '
                    'Retrying one figure at a time.'
                )
        else:
            logger.warning(
                'plotly.io.write_images is unavailable; install plotly>=6.1 with '
                'kaleido>=1.1 for batched figure export. Writing figures individually.'
            )

        for fig, path, scale in queued:
            try:
                fig.write_image(path, scale=scale)
            except Exception as e:
                logger.error(f'Could not write {path} ({type(e).__name__}: {e}). Skipping.')

    # plot energy consumption by fuel type and enduse
    """
    Plot a stacked bar graph of end uses by column_for_grouping
    Args:
        df: dataset with a comstock run
        column_for_grouping (str): discrete column for breaking out results, either by dataset or upgrade
        color_map: hash with dataset names as the keys
        output_dir (str): output directory
        applicability (str): 'stock' for the whole stock, 'applicable_only' for just applicable buildings, and 'both' for both.
    """
    def plot_energy_by_enduse_and_fuel_type(self, df, column_for_grouping, color_map, output_dir, applicability='both'):

        # ghg columns; uses Cambium low renewable energy cost 15-year for electricity
        cols_enduse_ann_en = self.COLS_ENDUSE_ANN_ENGY
        wtd_cols_enduse_ann_en = [self.col_name_to_weighted(c, 'tbtu') for c in cols_enduse_ann_en]
        cols_pv_ann_en = self.COLS_GEN_ANN_ENGY
        wtd_cols_pv_ann_en = [self.col_name_to_weighted(c, 'tbtu') for c in cols_pv_ann_en]
        cols_summarize = [self.ANN_TOT_ELEC_KBTU]
        wtd_cols_summarize = [self.col_name_to_weighted(c, 'tbtu') for c in cols_summarize]


        # plots for both applicable and total stock
        if applicability == 'both':
            scenarios = ['stock', 'applicable_only']
        if applicability == 'stock':
            scenarios = ['stock']
        if applicability == 'applicable_only':
            scenarios = ['applicable_only']

        for applicable_scenario in scenarios:

            df_scen = df.copy()

            # distringuish used vs excess PV
            pv_used = self.col_name_to_weighted('out.electricity.pv_used.energy_consumption..kwh', 'tbtu') # new col just for plotting
            pv_excess = self.col_name_to_weighted('out.electricity.pv_excess.energy_consumption..kwh', 'tbtu') # new col just for plotting
            df_scen[pv_used] = -(df_scen[self.col_name_to_weighted(self.ANN_TOT_ELEC_KBTU, 'tbtu')] - df_scen[self.col_name_to_weighted(self.ANN_PURCHASED_ELEC_KBTU, 'tbtu')])
            df_scen[pv_excess] = df_scen[self.col_name_to_weighted(self.ANN_ELEC_PV_KBTU, 'tbtu')] - df_scen[pv_used]

            if applicable_scenario == 'applicable_only':
                applic_bldgs = df_scen.loc[(df_scen[self.UPGRADE_NAME]!='Baseline') & (df_scen['applicability']==True), self.BLDG_ID]
                df_scen = df_scen.loc[df_scen[self.BLDG_ID].isin(applic_bldgs), :]

            df_emi_gb = (df_scen.groupby(column_for_grouping, observed=True)[wtd_cols_enduse_ann_en + wtd_cols_pv_ann_en + [pv_excess, pv_used]].sum()).reset_index()
            df_emi_gb = df_emi_gb.loc[:, (df_emi_gb !=0).any(axis=0)]
            df_emi_gb_long = df_emi_gb.melt(id_vars=[column_for_grouping], value_name='Annual Energy Consumption (TBtu)').sort_values(by='Annual Energy Consumption (TBtu)', ascending=False)

            # naming for plotting
            df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('calc.weighted.', '', regex=True)
            df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('.energy_consumption..tbtu', '', regex=True)
            # split end use and fuel names for coordianted color and texture assignments
            df_emi_gb_long[['Fuel Type', 'End Use']] = df_emi_gb_long['variable'].str.split('.', expand=True)
            df_emi_gb_long['Fuel Type'] = df_emi_gb_long['Fuel Type'].str.replace('_', ' ', regex=True)
            df_emi_gb_long['Fuel Type'] = df_emi_gb_long['Fuel Type'].str.title()
            df_emi_gb_long['End Use'] = df_emi_gb_long['End Use'].str.replace('_', ' ', regex=True)
            df_emi_gb_long['End Use'] = df_emi_gb_long['End Use'].str.title()
            df_emi_gb_long['End Use'] = df_emi_gb_long['End Use'].str.replace('Pv', 'Photovoltaics', regex=True)
            # remove columns not needed
            df_emi_gb_long = df_emi_gb_long.loc[~df_emi_gb_long['variable'].isin(['site_energy.net', 'electricity.net', 'electricity.purchased', 'electricity.pv']), :]

            ## add OS color map
            color_dict = self.ENDUSE_COLOR_DICT

            # set patterns by fuel type
            pattern_dict = {
                'Electricity': "",
                'Natural Gas':"/",
                'District Cooling':"x",
                'District Heating':".",
                'Fuel Oil': '+',
                'Propane': '-',
            }

            # set category orders by end use
            cat_order = {
               'End Use': [
                            'Photovoltaics Used',
                            'Photovoltaics Excess',
                            'Interior Equipment',
                            'Fans',
                            'Cooling',
                            'Interior Lighting',
                            'Heating',
                            'Water Systems',
                            'Exterior Lighting',
                            'Refrigeration',
                            'Pumps',
                            'Heat Recovery',
                            'Heat Rejection'],
                'Fuel Type': [
                            'Electricity',
                            'Natural Gas',
                            'District Cooling',
                            'District Heating',
                            'Fuel Oil',
                            'Propane',
                ]
            }

            # plot
            fig = px.bar(df_emi_gb_long, x=column_for_grouping, y='Annual Energy Consumption (TBtu)', color='End Use', pattern_shape='Fuel Type',
                    barmode='relative', text_auto='.1f', template='simple_white', width=700, category_orders=cat_order, color_discrete_map=color_dict,
                    pattern_shape_map=pattern_dict)

            # formatting and saving image
            title = 'ann_energy_by_enduse_and_fuel'
            # format title and axis
            # update plot width based on number of datasets (comstock versions or upgrades)
            set_count = df_emi_gb_long[column_for_grouping].nunique()
            plot_width=550
            if set_count <= 2:
                plot_width = 550
            else:
                extra_elements = set_count - 2
                plot_width = 550 * (1 + 0.15 * extra_elements)

            fig.update_traces(textposition='inside', width=0.5, textangle=0)
            fig.update_xaxes(type='category', mirror=True, showgrid=False, showline=True, title=None, ticks='outside', linewidth=1, linecolor='black',
                            categoryorder='array', categoryarray=np.array(list(color_map.keys())))
            fig.update_yaxes(mirror=True, showgrid=False, showline=True, ticks='outside', zeroline=True, linewidth=1, linecolor='black', rangemode="tozero")
            fig.update_layout(title=None,  margin=dict(l=20, r=20, t=27, b=20), width=plot_width, legend_title=None, legend_traceorder="reversed",
                            uniformtext_minsize=8, uniformtext_mode='hide', bargap=0.05)
            fig.update_layout(
                font=dict(
                    size=12)
                )

            # add summed values at top of bar charts
            df_emi_plot = df_emi_gb_long.loc[~df_emi_gb_long['End Use'].str.contains('Photovoltaics'),:].groupby(column_for_grouping, observed=True)['Annual Energy Consumption (TBtu)'].sum()
            fig.add_trace(go.Scatter(
                        x=df_emi_plot.index,
                        y=df_emi_plot,
                        text=round(df_emi_plot, 0),
                        mode='text',
                        textposition='top center',
                        textfont=dict(
                            size=12,
            ),
            showlegend=False
            ))

            # figure name and save
            fig_name = f'{title.replace(" ", "_").lower()}_{applicable_scenario}.{self.image_type}'
            fig_name_html = f'{title.replace(" ", "_").lower()}_{applicable_scenario}.html'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            fig_path_html = os.path.abspath(os.path.join(fig_sub_dir, fig_name_html))
            self.queue_figure(fig, fig_path, scale=10)
            #fig.write_html(fig_path_html)
            df_emi_gb_long.to_csv(os.path.join(fig_sub_dir, f'{title.replace(" ", "_").lower()}_{applicable_scenario}.csv'), index=False)

    # plot for GHG emissions by fuel type for baseline and upgrade
    def plot_emissions_by_fuel_type(self, df, column_for_grouping, color_map, output_dir):

        # ghg columns; uses Cambium low renewable energy cost 15-year for electricity
        ghg_cols = self.GHG_FUEL_COLS
        wtd_ghg_cols = [self.col_name_to_weighted(c, 'co2e_mmt') for c in ghg_cols]

        # groupby and long format for plotting
        df_emi_gb = (df.groupby(column_for_grouping, observed=True)[wtd_ghg_cols].sum()).reset_index()
        df_emi_gb_long = df_emi_gb.melt(id_vars=[column_for_grouping], value_name='Annual GHG Emissions (MMT CO2e)').sort_values(by='Annual GHG Emissions (MMT CO2e)', ascending=False)
        df_emi_gb_long.loc[:, 'in.upgrade_name'] = df_emi_gb_long['in.upgrade_name'].astype(str)

        # naming for plotting
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('ghg.weighted.', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('_emissions..co2e_mmt', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('..co2e_mmt', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('_emissions_', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('electricity', 'electricity:_', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('_', ' ', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.title()
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Lrmer', 'LRMER', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Egrid', 'eGRID', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Re', 'RE', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Calc.Weighted.Emissions.', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('calc.weighted.emissions.', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('.', '', regex=False)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Subregion', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace(' 2023 Start', '', regex=True)

        # plot
        order_map = list(color_map.keys()) # this will set baseline first in plots
        color_palette = sns.color_palette("colorblind")

        # update plot width based on number of upgrades
        upgrade_count = df_emi_gb_long[column_for_grouping].nunique()
        plot_width=8
        if upgrade_count <= 2:
            plot_width = 8
        else:
            extra_elements = upgrade_count - 2
            plot_width = 8 * (1 + 0.40 * extra_elements)

        # Create three vertical subplots with shared y-axis
        fig, axes = plt.subplots(1, 3, figsize=(plot_width, 3.4), sharey=True, gridspec_kw={'top': 1.2})
        plt.rcParams['axes.facecolor'] = 'white'
        # list of electricity grid scenarios
        electricity_scenarios = list(df_emi_gb_long[df_emi_gb_long['variable'].str.contains('electricity', case=False)]['variable'].unique())

        # loop through grid scenarios
        ax_position = 0
        for scenario in electricity_scenarios:

            # filter to grid scenario plus on-site combustion fuels
            df_scenario = df_emi_gb_long.loc[(df_emi_gb_long['variable']==scenario) | (df_emi_gb_long['variable'].isin(['Natural Gas', 'Fuel Oil', 'Propane']))].copy()

            # force measure ordering
            df_scenario['in.upgrade_name'] = pd.Categorical(df_scenario['in.upgrade_name'], categories=order_map, ordered=True)

            # Pivot the DataFrame to prepare for the stacked bars
            pivot_df = df_scenario.pivot(index='in.upgrade_name', columns='variable', values='Annual GHG Emissions (MMT CO2e)')

            # Sort the columns by the sum in descending order
            pivot_df = pivot_df[pivot_df.sum().sort_values(ascending=False).index]
            pivot_df = pivot_df.reindex(['Baseline'] + [idx for idx in pivot_df.index if idx != 'Baseline'])

            # # Set the color palette; colorblind friendly
            sns.set_palette(color_palette)

            # Create plot
            pivot_df.plot(kind='bar', stacked=True, ax=axes[ax_position], width=0.5)

            # Set the title for the specific subplot
            axes[ax_position].set_title(scenario.replace('Electricity:', ''))
            axes[ax_position].set_xticklabels(axes[ax_position].get_xticklabels())
            for ax in axes:
                for label in ax.get_xticklabels():
                    label.set_horizontalalignment('left')
                    label.set_rotation(-30)  # Rotate the labels for better visibility

            # remove x label
            axes[ax_position].set_xlabel(None)
            # Increase font size for text labels
            axes[ax_position].tick_params(axis='both', labelsize=12)
            # Add text labels to the bars for bars taller than a threshold
            threshold = 15*upgrade_count  # Adjust this threshold as needed
            for bar in axes[ax_position].containers:
                if bar.datavalues.sum() > threshold:
                    axes[ax_position].bar_label(bar, fmt='%.0f', padding=2, label_type='center')

            # Add aggregate values above the bars
            for i, v in enumerate(pivot_df.sum(axis=1)):
                # Display percentage savings only on the second bar
                if i != 0:
                    # Calculate percentage savings versus the first bar (baseline)
                    savings = (v - pivot_df.sum(axis=1).iloc[0]) / pivot_df.sum(axis=1).iloc[0] * 100
                    axes[ax_position].text(i, v + 2, f'{v:.0f} ({savings:.0f}%)', ha='center', va='bottom')
                else:
                    axes[ax_position].text(i, v + 2, f'{v:.0f}', ha='center', va='bottom')

            # increase axes position
            ax_position+=1

        # Create single plot legend
        handles, labels = axes[2].get_legend_handles_labels()
        # Modify the labels to simplify them
        labels = [label.replace('Electricity: LRMER Low RE Cost 15', 'Electricity') for label in labels]
        # Create a legend at the top of the plot, above the subplot titles
        fig.legend(handles, labels, title=None, loc='upper center', bbox_to_anchor=(0.5, 1.4), ncol=4)
        # Hide legends in the other subplots
        for ax in axes[:]:
            ax.get_legend().remove()
        # y label name
        axes[0].set_ylabel('Annual Emissions (MMT CO2e)', fontsize=14)

        # Add black boxes around the plot areas
        for ax in axes:
            for spine in ax.spines.values():
                spine.set_edgecolor('black')
        # Adjust spacing between subplots and reduce white space
        plt.subplots_adjust(wspace=0.2, hspace=0.2, bottom=0.15)
        # figure name and save
        title=f"GHG_emissions_{order_map[1]}"
        fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
        fig_sub_dir = os.path.abspath(os.path.join(output_dir))
        if not os.path.exists(fig_sub_dir):
            os.makedirs(fig_sub_dir)
        fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
        plt.savefig(fig_path, dpi=600, bbox_inches = 'tight')



    # plot for GHG emissions by fuel type for baseline and upgrade
    def plot_utility_bills_by_fuel_type(self, df, column_for_grouping, color_map, output_dir):

        # ghg columns; uses Cambium low renewable energy cost 15-year for electricity
        util_cols = self.COLS_UTIL_BILLS + ['out.utility_bills.electricity_bill_max..usd', 'out.utility_bills.electricity_bill_min..usd']
        wtd_util_cols = [self.col_name_to_weighted(c, 'billion_usd') for c in util_cols]

        # groupby and long format for plotting
        df_emi_gb = (df.groupby(column_for_grouping, observed=True)[wtd_util_cols].sum()).reset_index()
        df_emi_gb_long = df_emi_gb.melt(id_vars=[column_for_grouping], value_name='Annual Utility Bill (Billion USD)').sort_values(by='Annual Utility Bill (Billion USD)', ascending=False)
        df_emi_gb_long.loc[:, 'in.upgrade_name'] = df_emi_gb_long['in.upgrade_name'].astype(str)

        # naming for plotting
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('calc.weighted.', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('utility_bills.', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('..billion_usd', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('_', ' ', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.title()
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace(' Bill', '', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Electricity', 'Electricity Rate', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Electricity Rate Max', 'With Max Electricity Rate', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Electricity Rate Min', 'With Min Electricity Rate', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace('Electricity Rate Mean', 'With Mean Electricity Rate', regex=True)
        df_emi_gb_long['variable'] = df_emi_gb_long['variable'].str.replace(' State Average', '', regex=True)

        # plot
        order_map = list(color_map.keys()) # this will set baseline first in plots
        color_palette = sns.color_palette("colorblind")

        # update plot width based on number of upgrades
        upgrade_count = df_emi_gb_long[column_for_grouping].nunique()
        plot_width=9
        if upgrade_count <= 2:
            plot_width = 9
        else:
            extra_elements = upgrade_count - 2
            plot_width = 9 * (1 + 0.40 * extra_elements)

        # Create three vertical subplots with shared y-axis
        fig, axes = plt.subplots(1, 3, figsize=(plot_width, 3.4), sharey=True, gridspec_kw={'top': 1.2})
        plt.rcParams['axes.facecolor'] = 'white'
        # list of electricity grid scenarios
        electricity_scenarios = list(df_emi_gb_long[df_emi_gb_long['variable'].str.contains('electricity', case=False)]['variable'].unique())

        # loop through grid scenarios
        ax_position = 0
        for scenario in electricity_scenarios:

            # filter to grid scenario plus on-site combustion fuels
            df_scenario = df_emi_gb_long.loc[(df_emi_gb_long['variable']==scenario) | (df_emi_gb_long['variable'].isin(['Natural Gas', 'Fuel Oil', 'Propane']))].copy()

            # force measure ordering
            df_scenario['in.upgrade_name'] = pd.Categorical(df_scenario['in.upgrade_name'], categories=order_map, ordered=True)

            # Pivot the DataFrame to prepare for the stacked bars
            pivot_df = df_scenario.pivot(index='in.upgrade_name', columns='variable', values='Annual Utility Bill (Billion USD)')

            # Sort the columns by the sum in descending order
            pivot_df = pivot_df[pivot_df.sum().sort_values(ascending=False).index]
            pivot_df = pivot_df.reindex(['Baseline'] + [idx for idx in pivot_df.index if idx != 'Baseline'])

            # # Set the color palette; colorblind friendly
            sns.set_palette(color_palette)

            # Create plot
            pivot_df.plot(kind='bar', stacked=True, ax=axes[ax_position], width=0.5)

            # Set the title for the specific subplot
            axes[ax_position].set_title(scenario.replace('Electricity:', ''))
            axes[ax_position].set_xticklabels(axes[ax_position].get_xticklabels())
            for ax in axes:
                for label in ax.get_xticklabels():
                    label.set_horizontalalignment('left')
                    label.set_rotation(-30)  # Rotate the labels for better visibility

            # remove x label
            axes[ax_position].set_xlabel(None)
            # Increase font size for text labels
            axes[ax_position].tick_params(axis='both', labelsize=12)
            # Add text labels to the bars for bars taller than a threshold
            threshold = 20  # Adjust this threshold as needed
            for bar in axes[ax_position].containers:
                if bar.datavalues.sum() > threshold:
                    axes[ax_position].bar_label(bar, fmt='%.0f', padding=2, label_type='center')

            # Add aggregate values above the bars
            for i, v in enumerate(pivot_df.sum(axis=1)):
                # Display percentage savings only on the second bar
                if i != 0:
                    # Calculate percentage savings versus the first bar (baseline)
                    savings = (v - pivot_df.sum(axis=1).iloc[0]) / pivot_df.sum(axis=1).iloc[0] * 100
                    axes[ax_position].text(i, v + 2, f'{v:.0f} ({savings:.0f}%)', ha='center', va='bottom')
                else:
                    axes[ax_position].text(i, v + 2, f'{v:.0f}', ha='center', va='bottom')

            # increase axes position
            ax_position+=1


        # Calculate the maximum value among aggregate values
        max_aggregate_value = max(pivot_df.sum(axis=1))

        # Add a buffer to the maximum value
        buffer = 50  # You can adjust this buffer as needed
        max_y_value = max_aggregate_value + buffer

        # Set the same y-axis limits for all subplots
        for ax in axes:
            ax.set_ylim(0, max_y_value)

        # Create single plot legend
        handles, labels = axes[2].get_legend_handles_labels()
        # Modify the labels to simplify them
        labels = [label.replace('With Min Electricity Rate', 'Electricity') for label in labels]
        # Create a legend at the top of the plot, above the subplot titles
        fig.legend(handles, labels, title=None, loc='upper center', bbox_to_anchor=(0.5, 1.4), ncol=4)
        # Hide legends in the other subplots
        for ax in axes[:]:
            ax.get_legend().remove()
        # y label name
        axes[0].set_ylabel('Annual Utility Bill (Billion USD, 2022)', fontsize=14)

        # Add black boxes around the plot areas
        for ax in axes:
            for spine in ax.spines.values():
                spine.set_edgecolor('black')
        # Adjust spacing between subplots and reduce white space
        plt.subplots_adjust(wspace=0.25, hspace=0.2, bottom=0.15)
        # figure name and save
        fig_sub_dir = os.path.join(output_dir)
        if not os.path.exists(fig_sub_dir):
            os.makedirs(fig_sub_dir)
        fig_path = os.path.join(fig_sub_dir, "Annual Utility Bills by Fuel")
        plt.savefig(fig_path, dpi=600, bbox_inches = 'tight')


    # Plot for GHG emissions by fuel for baseline and EIA data
    def plot_annual_emissions_comparison(self, df, column_for_grouping, color_map, output_dir):
        # Summarize annual emissions by fuel

        # Columns to summarize
        weighted_ghg_units='co2e_mmt'
        cols_to_summarize = {
            self.col_name_to_weighted(self.GHG_ELEC_EGRID, weighted_ghg_units): np.sum,
            self.col_name_to_weighted(self.GHG_NATURAL_GAS, weighted_ghg_units): np.sum,
            self.col_name_to_weighted(self.GHG_FUEL_OIL, weighted_ghg_units): np.sum,
            self.col_name_to_weighted(self.GHG_PROPANE, weighted_ghg_units): np.sum,
        }

        # Disaggregate to these levels
        group_bys = [
            None,
        ]

        for col, agg_method in cols_to_summarize.items(): # loops through column names and provides agg function for specific column

            for group_by in group_bys: # loops through group by options

                # Summarize the data
                if group_by is None:
                    # No group-by
                    g = sns.catplot(
                        data=df,
                        x=column_for_grouping,
                        hue=column_for_grouping,
                        y=col,
                        estimator=agg_method,
                        order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='bar',
                        errorbar=None,
                        aspect=1.5,
                        legend=False,
                        dodge=False
                    )
                else:
                    # With group-by
                    g = sns.catplot(
                        data=df,
                        y=col,
                        estimator=agg_method,
                        hue=column_for_grouping,
                        x=group_by,
                        order=self.ORDERED_CATEGORIES[group_by],
                        hue_order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='bar',
                        errorbar=None,
                        aspect=2
                    )
                    g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                fig = g.figure

                # Extract the units from the column name
                units = self.nice_units(self.units_from_col_name(col))

                # Title and axis labels
                if group_by is None:
                    # No group-by
                    title = f'{self.col_name_to_nice_name(col)}'
                    for ax in g.axes.flatten():
                        ax.set_ylabel(f'{self.col_name_to_nice_name(col)} ({units})')
                        ax.set_xlabel('')
                        ax.tick_params(axis='x', labelrotation = 90)
                else:
                    # With group-by
                    title = f'{self.col_name_to_nice_name(col)}\n by {self.col_name_to_nice_name(group_by)}'
                    for ax in g.axes.flatten():
                        ax.set_ylabel(f'{self.col_name_to_nice_name(col)} ({units})')
                        ax.set_xlabel(f'{self.col_name_to_nice_name(group_by)}')
                        ax.tick_params(axis='x', labelrotation = 90)

                # Formatting
                fig.subplots_adjust(top=0.9)

                # Save figure
                title = title.replace('\n', '')
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                plt.savefig(fig_path, bbox_inches = 'tight')
                plt.close()

    def normalize_energy_for_hvac_sys(self, df):

         grouped_df = df.groupby([self.HVAC_SYS, self.CEN_DIV, self.VINTAGE,'dataset'], observed=True).sum(numeric_only=True).reset_index()

         new_cols = pd.DataFrame({
             'Normalized_Total_Energy': self.convert(grouped_df[self.col_name_to_weighted(self.ANN_TOT_ENGY_KBTU, 'tbtu')], 'tbtu', 'kbtu') / grouped_df[self.col_name_to_weighted(self.FLR_AREA)],
             'Normalized_Electric_Energy': self.convert(grouped_df[self.col_name_to_weighted(self.ANN_TOT_ELEC_KBTU, 'tbtu')], 'tbtu', 'kbtu') / grouped_df[self.col_name_to_weighted(self.FLR_AREA)],
             'Normalized_Gas_Energy': self.convert(grouped_df[self.col_name_to_weighted(self.ANN_TOT_GAS_KBTU, 'tbtu')], 'tbtu', 'kbtu') / grouped_df[self.col_name_to_weighted(self.FLR_AREA)]
         })

         nm_df = pd.concat([grouped_df, new_cols], axis=1)
         return nm_df




    def plot_floor_area_and_energy_totals_grouped_hvac(self, df, column_for_grouping, color_map, output_dir):
        nm_df = self.normalize_energy_for_hvac_sys(df)

        cols_to_summarize = {
            'Normalized_Total_Energy',
            'Normalized_Electric_Energy',
            'Normalized_Gas_Energy',
        }

        group_bys = [self.HVAC_SYS]

        for col in cols_to_summarize:
            for group_by in group_bys:
                g = sns.catplot(
                    data=nm_df.reset_index(),
                    y=col,
                    hue=column_for_grouping,
                    x=group_by,
                    order=self.ORDERED_CATEGORIES[group_by],
                    hue_order=list(color_map.keys()),
                    palette=color_map.values(),
                    kind='bar',
                    errorbar=None,
                    aspect=3
                )
                g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))
                g.set_xticklabels(rotation=90)
                fig = g.figure
                units = self.nice_units(self.units_from_col_name(col))

                if group_by is self.HVAC_SYS:
                    title = f'normalized {self.col_name_to_nice_name(col)} by {self.col_name_to_nice_name(group_by)}'
                    for ax in g.axes.flatten():
                        ax.set_ylabel(f'{self.col_name_to_nice_name(col)} (kBtu/ft²)')
                        ax.set_xlabel(self.col_name_to_nice_name(group_by))
                        ax.tick_params(axis='x', labelrotation=90)

                fig.subplots_adjust(top=0.9)
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_name = fig_name.replace('_total_energy_consumption', '')
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                plt.savefig(fig_path, bbox_inches='tight')
                plt.close()


    def plot_floor_area_and_energy_totals(self, df, column_for_grouping, color_map, output_dir):
        # Summarize square footage and energy totals

        # Columns to summarize
        cols_to_summarize = {
            self.col_name_to_weighted(self.FLR_AREA): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_ENGY_KBTU, 'tbtu'): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_ELEC_KBTU, 'tbtu'): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_GAS_KBTU, 'tbtu'): np.sum,
        }

        # Disaggregate to these levels
        group_bys = [
            None,
            self.CEN_DIV,
            self.BLDG_TYPE,
            # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
            self.VINTAGE,
        ]


        # Loop through columns and group-bys for charting
        for col, agg_method in cols_to_summarize.items():
            for group_by in group_bys:
                # Only calculate CI for CBECS utilizing CBECS replicate weight and RSE calculations
                cbecs_mask = df[column_for_grouping].astype(str).str.startswith('CBECS')
                cbecs_df = df[cbecs_mask]
                rse_results = None
                # Always include dataset in grouping for RSE calculation
                if not cbecs_df.empty:
                    if group_by is None:
                        rse_results = rse_by_group_total(
                            cbecs_df,
                            value_col=col,
                            by=column_for_grouping,  # dataset only
                            weight_col='weight',
                            already_weighted=True # This should always be true
                        )
                    else:
                        rse_results = rse_by_group_total(
                            cbecs_df,
                            value_col=col,
                            by=[group_by, column_for_grouping],  # group + dataset
                            weight_col='weight',
                            already_weighted=True
                        )
                # Summarize the data
                if group_by is None:
                    g = sns.catplot(
                        data=df,
                        x=column_for_grouping,
                        hue=column_for_grouping,
                        y=col,
                        estimator=agg_method,
                        order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='bar',
                        errorbar=None,
                        aspect=1.5,
                        legend=False,
                        dodge=False
                    )
                    ax = g.ax if hasattr(g, 'ax') else g.axes[0, 0]
                    # Add error bars for CBECS bars only
                    if rse_results is not None:
                        for i, dataset in enumerate(list(color_map.keys())):
                            if str(dataset).startswith('CBECS'):
                                match = rse_results[rse_results[column_for_grouping] == dataset]
                                if not match.empty:
                                    y = match['estimate'].values[0]
                                    yerr = [[y - match['ci95_low'].values[0]], [match['ci95_high'].values[0] - y]]
                                    ax.errorbar(i, y, yerr=np.array(yerr), fmt='none', ecolor='black', capsize=4)
                else:
                    g = sns.catplot(
                        data=df,
                        y=col,
                        estimator=agg_method,
                        hue=column_for_grouping,
                        x=group_by,
                        order=self.ORDERED_CATEGORIES[group_by],
                        hue_order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='bar',
                        errorbar=None,
                        aspect=2
                    )
                    ax = g.ax if hasattr(g, 'ax') else g.axes[0, 0]
                    # Add error bars for CBECS bars only
                    if rse_results is not None:
                        for i, cat in enumerate(self.ORDERED_CATEGORIES[group_by]):
                            for j, dataset in enumerate(list(color_map.keys())):
                                if str(dataset).startswith('CBECS'):
                                    match = rse_results[(rse_results[group_by] == cat) & (rse_results[column_for_grouping] == dataset)]
                                    if not match.empty:
                                        y = match['estimate'].values[0]
                                        yerr = [[y - match['ci95_low'].values[0]], [match['ci95_high'].values[0] - y]]
                                        ax.errorbar(i - 0.2, y, yerr=np.array(yerr), fmt='none', ecolor='black', capsize=4)
                    g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                fig = g.figure
                units = self.nice_units(self.units_from_col_name(col))
                if group_by is None:
                    title = f'{self.col_name_to_nice_name(col)}'
                    for ax in g.axes.flatten():
                        ax.set_ylabel(f'{self.col_name_to_nice_name(col)} ({units})')
                        ax.tick_params(axis='x', labelrotation=90)
                else:
                    title = f'{self.col_name_to_nice_name(col)}\n by {self.col_name_to_nice_name(group_by)}'
                    for ax in g.axes.flatten():
                        ax.set_ylabel(f'{self.col_name_to_nice_name(col)} ({units})')
                        ax.set_xlabel(f'{self.col_name_to_nice_name(group_by)}')
                        ax.tick_params(axis='x', labelrotation=90)
                fig.subplots_adjust(top=0.9)
                title = title.replace('\n', '')
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_name = fig_name.replace('_total_energy_consumption', '')
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                plt.savefig(fig_path, bbox_inches='tight')
                plt.close()

    def plot_eui_boxplots(self, df, column_for_grouping, color_map, output_dir, make_hvac_plots):
        # EUI box plot comparisons by building type and several disaggregations

        # Columns to summarize
        cols_to_summarize = [
            self.col_name_to_eui(self.ANN_TOT_ENGY_KBTU),
            self.col_name_to_eui(self.ANN_TOT_ELEC_KBTU),
            self.col_name_to_eui(self.ANN_TOT_GAS_KBTU),
        ]

        # Disaggregate to these levels
        group_bys = [
            None,
            self.BLDG_TYPE,
        ]
        if make_hvac_plots:
            group_bys.append(self.HVAC_SYS)
        logger.info('Weighting DF for EUI boxplots this can take a while')

        weighted_df = df.copy()
        # Expand the dataframe according to building weights using stochastic rounding
        weighted_df = weighted_df.loc[
            weighted_df.index.repeat(
                (np.floor(weighted_df[self.BLDG_WEIGHT]) +
                (np.random.random(len(weighted_df)) <
                (weighted_df[self.BLDG_WEIGHT] - np.floor(weighted_df[self.BLDG_WEIGHT]))).astype(int)
                ).astype(int)
            )
        ].reset_index(drop=True)
        for col in cols_to_summarize:
            # Make a plot for each group
            for group_by in group_bys:
                if group_by is None:
                    # No group-by
                    g = sns.catplot(
                        data=weighted_df,
                        y=column_for_grouping,
                        hue=column_for_grouping,
                        x=col,
                        order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='box',
                        aspect=5,
                        height=3,
                        orient='h',
                        showfliers=False,
                        showmeans=True,
                        meanprops={"marker":"d",
                            "markerfacecolor":"yellow",
                            "markeredgecolor":"black",
                            "markersize":"2"
                        },
                        legend=False,
                        dodge=False
                    )
                elif group_by is self.HVAC_SYS:
                    g = sns.catplot(
                        data=weighted_df,
                        x=col,
                        hue=column_for_grouping,
                        y=group_by,
                        order=self.ORDERED_CATEGORIES[group_by],
                        hue_order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='box',
                        aspect=2,
                        height=10,
                        orient='h',
                        showfliers=False,
                        showmeans=True,
                        meanprops={"marker":"d",
                            "markerfacecolor":"yellow",
                            "markeredgecolor":"black",
                            "markersize":"2"
                        },
                    )
                    g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))
                else:
                    # With group-by
                    g = sns.catplot(
                        data=weighted_df,
                        x=col,
                        hue=column_for_grouping,
                        y=group_by,
                        order=self.ORDERED_CATEGORIES[group_by],
                        hue_order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='box',
                        aspect=5,
                        height=3,
                        orient='h',
                        showfliers=False,
                        showmeans=True,
                        meanprops={"marker":"d",
                            "markerfacecolor":"yellow",
                            "markeredgecolor":"black",
                            "markersize":"2"
                        },
                    )
                    g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                fig = g.figure

                # Extract the units from the column name
                units = self.nice_units(self.units_from_col_name(col))

                # Titles and axis labels
                col_title = self.col_name_to_nice_name(col)
                fuel = self.col_name_to_fuel(col_title)

                # Formatting
                if group_by is None:
                    # No group-by
                    title = f"Boxplot of {col_title}".title()
                    for ax in g.axes.flatten():
                        ax.set_xlabel(f'{fuel} EUI ({units})')
                        ax.set_ylabel('')
                else:
                    # With group-by
                    gb = self.col_name_to_nice_name(group_by)
                    title = f"Boxplot of {col_title} by {f'{gb}'}".title()
                    for ax in g.axes.flatten():
                        ax.set_xlabel(f'{fuel} EUI ({units})')
                        ax.set_ylabel(f'{gb}')

                # Save figure
                title = title.replace('\n', '')
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_name = fig_name.replace('boxplot_of_', 'bp_')
                fig_name = fig_name.replace('total_energy_consumption_', '')
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                if group_by is self.HVAC_SYS:
                     plt.savefig(fig_path)
                     plt.close()
                else:
                    plt.gcf().set_size_inches(10, 8)  # Adjust the size of the plot as needed
                    plt.tight_layout()
                    plt.savefig(fig_path)
                    plt.close()

    def plot_energy_rate_boxplots(self, df, column_for_grouping, color_map, output_dir):
        # energy rate box plot comparisons by building type and several disaggregations

        # Columns to summarize
        cols_to_summarize = [
            self.col_name_to_energy_rate(self.UTIL_BILL_ELEC),
            self.col_name_to_energy_rate(self.UTIL_BILL_GAS),
        ]

        # Disaggregate to these levels
        group_bys = [
            self.CEN_DIV,
            self.BLDG_TYPE
        ]

        for col in cols_to_summarize:
            # for bldg_type, bldg_type_ts_df in df.groupby(self.BLDG_TYPE, observed=True):

            # Make a plot for each group
            for group_by in group_bys:
                if group_by is None:
                    # No group-by
                    g = sns.catplot(
                        data=df,
                        y=column_for_grouping,
                        hue=column_for_grouping,
                        x=col,
                        order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='box',
                        orient='h',
                        showfliers=False,
                        showmeans=True,
                        meanprops={"marker":"d",
                            "markerfacecolor":"yellow",
                            "markeredgecolor":"black",
                            "markersize":"8"
                        },
                        legend=False,
                        dodge=False
                    )
                else:
                    # With group-by
                    g = sns.catplot(
                        data=df,
                        x=col,
                        hue=column_for_grouping,
                        y=group_by,
                        order=self.ORDERED_CATEGORIES[group_by],
                        hue_order=list(color_map.keys()),
                        palette=color_map.values(),
                        kind='box',
                        orient='h',
                        showfliers=False,
                        showmeans=True,
                        meanprops={"marker":"d",
                            "markerfacecolor":"yellow",
                            "markeredgecolor":"black",
                            "markersize":"8"
                        },
                        aspect=2
                    )
                    g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                fig = g.figure

                # Extract the units from the column name
                units = self.nice_units(self.units_from_col_name(col))

                # Titles and axis labels
                col_title = self.col_name_to_nice_name(col)
                fuel = self.col_name_to_fuel(col_title)

                # Formatting
                if group_by is None:
                    # No group-by
                    title = f"Boxplot of {col_title}".title()
                    for ax in g.axes.flatten():
                        ax.set_xlabel(f'{fuel} rate ({units})')
                        ax.set_ylabel('')
                else:
                    # With group-by
                    gb = self.col_name_to_nice_name(group_by)
                    title = f"Boxplot of {col_title} by {f'{gb}'}".title()
                    for ax in g.axes.flatten():
                        ax.set_xlabel(f'{fuel} rate ({units})')
                        ax.set_ylabel(f'{gb}')

                # Save figure
                title = title.replace('\n', '')
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_name = fig_name.replace('boxplot_of_', 'bp_')
                # fig_name = fig_name.replace('total_energy_consumption_', '')
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                plt.savefig(fig_path, bbox_inches = 'tight')
                plt.close()

    def plot_floor_area_and_energy_totals_by_building_type(self, df, column_for_grouping, color_map, output_dir):
        # Summarize square footage and energy totals by building type

        # Columns to summarize
        cols_to_summarize = {
            self.col_name_to_weighted(self.FLR_AREA): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_ENGY_KBTU, 'tbtu'): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_ELEC_KBTU, 'tbtu'): np.sum,
            self.col_name_to_weighted(self.ANN_TOT_GAS_KBTU, 'tbtu'): np.sum,
        }

        # Disaggregate to these levels
        group_bys = [
            None,
            self.CEN_DIV,
            # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
            # self.VINTAGE,
        ]

        for col, agg_method in cols_to_summarize.items():
            for bldg_type, bldg_type_ts_df in df.groupby(self.BLDG_TYPE, observed=True):

                # Always include dataset in grouping for RSE calculation
                for group_by in group_bys:
                    # Only calculate CI for CBECS within this building type utilizing replicate weights
                    cbecs_mask = bldg_type_ts_df[column_for_grouping].astype(str).str.startswith('CBECS')
                    cbecs_df = bldg_type_ts_df[cbecs_mask]
                    rse_results = None
                    if not cbecs_df.empty:
                        if group_by is None:
                            rse_results = rse_by_group_total(
                                cbecs_df,
                                value_col=col,
                                by=column_for_grouping,  # dataset only
                                weight_col='weight',
                                already_weighted=True
                            )
                        else:
                            rse_results = rse_by_group_total(
                                cbecs_df,
                                value_col=col,
                                by=[group_by, column_for_grouping],  # group + dataset
                                weight_col='weight',
                                already_weighted=True
                            )

                    # Make a plot for each group
                    if group_by is None:
                        # No group-by
                        g = sns.catplot(
                            data=bldg_type_ts_df,
                            x=column_for_grouping,
                            hue=column_for_grouping,
                            y=col,
                            estimator=agg_method,
                            order=list(color_map.keys()),
                            palette=color_map.values(),
                            errorbar=None,
                            kind='bar',
                            aspect=1.5,
                            legend=False,
                            dodge=False
                        )
                        ax = g.ax if hasattr(g, 'ax') else g.axes[0, 0]
                        # Add error bars for CBECS bars only
                        if rse_results is not None:
                            for i, dataset in enumerate(list(color_map.keys())):
                                if str(dataset).startswith('CBECS'):
                                    match = rse_results[rse_results[column_for_grouping] == dataset]
                                    if not match.empty:
                                        y = match['estimate'].values[0]
                                        yerr = [[y - match['ci95_low'].values[0]], [match['ci95_high'].values[0] - y]]
                                        ax.errorbar(i, y, yerr=np.array(yerr), fmt='none', ecolor='black', capsize=4)
                    else:
                        # With group-by
                        g = sns.catplot(
                            data=bldg_type_ts_df,
                            y=col,
                            hue=column_for_grouping,
                            x=group_by,
                            estimator=agg_method,
                            order=self.ORDERED_CATEGORIES[group_by],
                            hue_order=list(color_map.keys()),
                            palette=color_map.values(),
                            kind='bar',
                            errorbar=None,
                            aspect=2
                        )
                        ax = g.ax if hasattr(g, 'ax') else g.axes[0, 0]
                        # Add error bars for CBECS bars only
                        if rse_results is not None:
                            for i, cat in enumerate(self.ORDERED_CATEGORIES[group_by]):
                                for _, dataset in enumerate(list(color_map.keys())):
                                    if str(dataset).startswith('CBECS'):
                                        match = rse_results[(rse_results[group_by] == cat) & (rse_results[column_for_grouping] == dataset)]
                                        if not match.empty:
                                            y = match['estimate'].values[0]
                                            yerr = [[y - match['ci95_low'].values[0]], [match['ci95_high'].values[0] - y]]
                                            ax.errorbar(i - 0.2, y, yerr=np.array(yerr), fmt='none', ecolor='black', capsize=4)
                        g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                    fig = g.figure

                    # Extract the units from the column name
                    units = self.nice_units(self.units_from_col_name(col))

                    # Titles and axis labels
                    col_title = self.col_name_to_nice_name(col)
                    # col_title = col.replace(f' {units}', '')
                    # col_title = col_title.replace('Normalized Annual ', '')

                    # Formatting
                    if group_by is None:
                        # No group-by
                        title = f"{col_title}\n for {bldg_type.replace('_', ' ')}".title()
                        for ax in g.axes.flatten():
                            ax.set_ylabel(f'{col_title} ({units})')
                            ax.set_xlabel('')
                    else:
                        # With group-by
                        gb = self.col_name_to_nice_name(group_by)
                        title = f"{col_title}\n for {bldg_type.replace('_', ' ')} by {f'{gb}'}".title()
                        for ax in g.axes.flatten():
                            ax.set_ylabel(f'{col_title} ({units})')
                            ax.set_xlabel(f'{gb}')
                            ax.tick_params(axis='x', labelrotation = 90)

                    # Save figure
                    title = title.replace('\n', '')
                    fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                    fig_name = fig_name.replace('_total_energy_consumption', '')
                    fig_sub_dir = os.path.abspath(os.path.join(output_dir, bldg_type))
                    if not os.path.exists(fig_sub_dir):
                        os.makedirs(fig_sub_dir)
                    fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
                    plt.savefig(fig_path, bbox_inches = 'tight')
                    plt.close()

    def plot_floor_area_and_energy_totals_by_hvac_type(self, df, column_for_grouping, color_map, output_dir):
        # Summarize square footage and energy totals by HVAC system type
        nm_df = self.normalize_energy_for_hvac_sys(df)

        cols_to_summarize = [
            'Normalized_Total_Energy',
            'Normalized_Electric_Energy',
            'Normalized_Gas_Energy',
        ]

        group_bys = [
            None,
            self.CEN_DIV,
            self.VINTAGE,
        ]

        for col in cols_to_summarize:
            for hvac_type, hvac_type_df in nm_df.groupby(self.HVAC_SYS, observed=True):
                for group_by in group_bys:
                    if group_by is None:
                        g = sns.catplot(
                            data=hvac_type_df.reset_index(),
                            x=column_for_grouping,
                            hue=column_for_grouping,
                            y=col,
                            order=list(color_map.keys()),
                            palette=color_map.values(),
                            errorbar=None,
                            kind='bar',
                            aspect=1.5,
                            legend=False,
                            dodge=False
                        )
                    else:
                        g = sns.catplot(
                            data=hvac_type_df,
                            y=col,
                            hue=column_for_grouping,
                            x=group_by,
                            order=self.ORDERED_CATEGORIES[group_by],
                            hue_order=list(color_map.keys()),
                            palette=color_map.values(),
                            kind='bar',
                            errorbar=None,
                            aspect=2
                        )
                        g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                    fig = g.figure

                    # Extract the units from the column name
                    units = f'{self.nice_units(self.units_from_col_name(col))}/ft^2'

                    # Titles and axis labels
                    col_title = self.col_name_to_nice_name(col)

                    if group_by is None:
                        title = f"{col_title}\n for {hvac_type.replace('_', ' ')}".title()
                        for ax in g.axes.flatten():
                            ax.set_ylabel(f'{col_title} ({units})')
                            ax.set_xlabel('')
                            ax.tick_params(axis='x', labelrotation = 90)
                    else:
                        gb = self.col_name_to_nice_name(group_by)
                        title = f"{col_title}\n for {hvac_type.replace('_', ' ')} by {f'{gb}'}".title()
                        for ax in g.axes.flatten():
                            ax.set_ylabel(f'normalized {col_title} (kbtu/ft^2)')
                            ax.set_xlabel(f'{gb}')
                            ax.tick_params(axis='x', labelrotation = 90)

                    # Save figure
                    title = title.replace('\n', '')
                    fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                    fig_name = fig_name.replace('_total_normalized_energy_consumption', '')
                    fig_sub_dir = os.path.join(output_dir,'HVAC Charts', hvac_type)
                    if not os.path.exists(fig_sub_dir):
                        os.makedirs(fig_sub_dir)
                    fig_path = os.path.join(fig_sub_dir, fig_name)
                    plt.savefig(fig_path, bbox_inches = 'tight')
                    plt.close()

    def plot_eui_boxplots_by_hvac_type(self, df, column_for_grouping, color_map, output_dir):
         # EUI box plot comparisons by HVAC type and several disaggregations

         # Columns to summarize
         cols_to_summarize = [
             self.col_name_to_eui(self.ANN_TOT_ENGY_KBTU),
             self.col_name_to_eui(self.ANN_TOT_ELEC_KBTU),
             self.col_name_to_eui(self.ANN_TOT_GAS_KBTU)
         ]

         # Disaggregate to these levels
         group_bys = [
             None,
             self.CEN_DIV,
             # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
             self.VINTAGE,
             self.BLDG_TYPE
         ]
         logger.info('Weighting DF for HVAC System Type EUI boxplots this can take a while')

         weighted_df = df.copy()
         # Expand the dataframe according to building weights using stochastic rounding
         weighted_df = weighted_df.loc[
             weighted_df.index.repeat(
                 (np.floor(weighted_df[self.BLDG_WEIGHT]) +
                  (np.random.random(len(weighted_df)) <
                   (weighted_df[self.BLDG_WEIGHT] - np.floor(weighted_df[self.BLDG_WEIGHT]))).astype(int)
                  ).astype(int)
             )
         ].reset_index(drop=True)

         for col in cols_to_summarize:
             for hvac_type, hvac_type_df in weighted_df.groupby(self.HVAC_SYS, observed=True):
                 if hvac_type_df[col].isnull().all():
                     print(f"No data for {col} in HVAC type {hvac_type}. Skipping plot.")
                     continue  # Skip this HVAC type if the column is all NaNs or empty

                 for group_by in group_bys:
                     try:
                         if group_by is None:
                             g = sns.catplot(
                                data=hvac_type_df,
                                y=column_for_grouping,
                                hue=column_for_grouping,
                                x=col,
                                order=list(color_map.keys()),
                                palette=list(color_map.values()),
                                kind='box',
                                aspect=5,
                                height=3,
                                orient='h',
                                showfliers=False,
                                showmeans=True,
                                meanprops={"marker": "d",
                                        "markerfacecolor": "yellow",
                                        "markeredgecolor": "black",
                                        "markersize": "2"},
                                legend_out=False,  # Draw legend inside the plot area
                                dodge=False
                             )
                         else:
                             g = sns.catplot(
                                data=hvac_type_df,
                                x=col,
                                hue=column_for_grouping,
                                y=group_by,
                                order=self.ORDERED_CATEGORIES[group_by],
                                hue_order=list(color_map.keys()),
                                palette=list(color_map.values()),
                                kind='box',
                                aspect=5,
                                height=3,
                                orient='h',
                                fliersize=0,
                                showmeans=True,
                                meanprops={"marker": "d",
                                        "markerfacecolor": "yellow",
                                        "markeredgecolor": "black",
                                        "markersize": "8"},
                                legend_out=False  # Draw legend inside the plot area
                             )

                         if g._legend is not None:
                            g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))
                            # Reduce legend font size
                            for text in g._legend.get_texts():
                                text.set_fontsize('small')
                            # Adjust legend frame
                            g._legend.get_frame().set_edgecolor('black')
                            g._legend.get_frame().set_linewidth(0.5)
                            g._legend.get_frame().set_alpha(0.8)
                            g._legend.set_bbox_to_anchor((1, 0.5))

                         fig = g.figure

                         units = self.nice_units(self.units_from_col_name(col))
                         col_title = self.col_name_to_nice_name(col)
                         fuel = self.col_name_to_fuel(col_title)

                         if group_by is None:
                             title = f"Boxplot of {col_title}\n for {hvac_type.replace('_', ' ')}".title()
                             for ax in g.axes.flatten():
                                 ax.set_xlabel(f'{fuel} EUI ({units})')
                                 ax.set_ylabel('')
                         else:
                             gb = self.col_name_to_nice_name(group_by)
                             title = f"Boxplot of {col_title}\n for {hvac_type.replace('_', ' ')} by {f'{gb}'}".title()
                             for ax in g.axes.flatten():
                                 ax.set_xlabel(f'{fuel} EUI ({units})')
                                 ax.set_ylabel(f'{gb}')

                         title = title.replace('\n', '')
                         fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                         fig_name = fig_name.replace('boxplot_of_', 'bp_')
                         fig_name = fig_name.replace('total_energy_consumption_', '')
                         fig_sub_dir = os.path.join(output_dir, 'HVAC Charts', hvac_type)
                         if not os.path.exists(fig_sub_dir):
                             os.makedirs(fig_sub_dir)
                         fig_path = os.path.join(fig_sub_dir, fig_name)
                         plt.close(fig)
                         print(f"Successfully created plot for {col} and {hvac_type} with group_by {group_by}")

                     except Exception as e:
                         print(f"Failed to create plot for {col} and {hvac_type} with group_by {group_by}. Error: {e}")

    def plot_end_use_totals_by_building_type(self, df, column_for_grouping, color_map, output_dir):
        # Summarize end use energy totals by building type

        # End uses to include
        end_use_cols = self.COLS_ENDUSE_ANN_ENGY
        wtd_end_use_cols = [self.col_name_to_weighted(c, 'tbtu') for c in end_use_cols]

        # Grocery-specific refrigeration defrost detail columns (subset of refrigeration)
        grocery_detail_wtd_cols_med_temp = [
            self.col_name_to_weighted(c, 'tbtu') for c in self.COLS_GROCERY_REFRIG_MED_TEMP_DEFROST_ENDUSE
            if self.col_name_to_weighted(c, 'tbtu') in df.columns
        ]
        grocery_detail_wtd_cols_low_temp = [
            self.col_name_to_weighted(c, 'tbtu') for c in self.COLS_GROCERY_REFRIG_LOW_TEMP_DEFROST_ENDUSE
            if self.col_name_to_weighted(c, 'tbtu') in df.columns
        ]

        # Disaggregate to these levels (now supports None)
        group_bys = [
            None,
            self.CEN_DIV,
            # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
            # self.VINTAGE,
        ]

        # How the data will be combined
        agg_method = np.sum  # Could use np.mean etc. for different look at data

        # Extract the units from the name of the first column
        units = self.nice_units(self.units_from_col_name(wtd_end_use_cols[0]))
        hue_order = list(color_map.keys())
        palette = [color_map[name] for name in hue_order]
        row_name = 'Fuel and End Use'

        for bldg_type, bldg_type_df in df.groupby(self.BLDG_TYPE, observed=True):
            # Include refrigeration defrost detail columns for Grocery buildings
            if bldg_type == 'Grocery' and (grocery_detail_wtd_cols_med_temp or grocery_detail_wtd_cols_low_temp):
                wtd_end_use_cols_this = wtd_end_use_cols + grocery_detail_wtd_cols_med_temp + grocery_detail_wtd_cols_low_temp
            else:
                wtd_end_use_cols_this = wtd_end_use_cols

            row_label_map = {
                col: self.col_name_to_nice_name(col).replace(' Energy Consumption', '')
                for col in wtd_end_use_cols_this
            }
            row_order = [row_label_map[col] for col in wtd_end_use_cols_this]

            for group_by in group_bys:
                # --- Minimal additions to support None group_by ---
                if group_by is None:
                    # Use a temporary single-bin x-axis
                    _tmp_all_col = "__ALL__"
                    bldg_type_df_local = bldg_type_df.copy()
                    bldg_type_df_local[_tmp_all_col] = "Total"
                    x_col = _tmp_all_col
                    x_order = ["Total"]
                    gb = "Total"
                else:
                    bldg_type_df_local = bldg_type_df
                    x_col = group_by
                    x_order = self.ORDERED_CATEGORIES[group_by]
                    gb = self.col_name_to_nice_name(group_by)
                # ---------------------------------------------------

                var_name = 'End Use'
                val_name = f'Energy Consumption ({units})'

                # id_vars: include the chosen x_col instead of raw group_by
                tots_long = pd.melt(
                    bldg_type_df_local,
                    id_vars=[
                        column_for_grouping,
                        x_col
                    ],
                    value_vars=wtd_end_use_cols_this,
                    var_name=var_name,
                    value_name=val_name
                )
                tots_long[column_for_grouping] = pd.Categorical(
                    tots_long[column_for_grouping].astype(str),
                    categories=hue_order,
                    ordered=True,
                )
                tots_long[row_name] = pd.Categorical(
                    tots_long[var_name].map(row_label_map),
                    categories=row_order,
                    ordered=True,
                )

                g = sns.catplot(
                    data=tots_long,
                    x=x_col,
                    y=val_name,
                    row=row_name,
                    hue=column_for_grouping,
                    estimator=agg_method,
                    order=x_order,
                    row_order=row_order,
                    hue_order=hue_order,
                    palette=palette,
                    sharex=False,
                    kind='bar',
                    errorbar=None,
                    aspect=3
                )
                g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                fig = g.figure

                # Titles and axis labels
                title = f"End Use Energy Consumption \n for {bldg_type.replace('_', ' ')} by {gb}".title()
                for ax in g.axes.flatten():
                    # Improve the title and move to the y-axis label
                    ax_title = ax.get_title()
                    ax_title = ax_title.replace(f'{row_name} = ', '')
                    ax_title = f'{ax_title} ({units})'
                    ax_title = ax_title.replace(' ', '\n')
                    ax.set_ylabel(ax_title, rotation=0, ha='right')
                    ax.set_title('')
                    ax.set_xlabel(gb)

                g.tight_layout()

                # Save figure
                title = title.replace('\n', '')
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_sub_dir = os.path.abspath(os.path.join(output_dir, bldg_type))
                if not os.path.exists(fig_sub_dir):
                    os.makedirs(fig_sub_dir)
                fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
                plt.savefig(fig_path, bbox_inches='tight')
                plt.close()


    def plot_eui_histograms_by_building_type(self, df, column_for_grouping, color_map, output_dir):
        # EUI histogram comparisons by building type

        # Columns to summarize
        cols_to_summarize = [
            self.col_name_to_eui(self.ANN_TOT_ENGY_KBTU),
            self.col_name_to_eui(self.ANN_TOT_ELEC_KBTU),
            self.col_name_to_eui(self.ANN_TOT_GAS_KBTU),
        ]

        # Disaggregate to these levels
        group_bys = [
            None,
            # self.CEN_DIV,
            # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
            # self.VINTAGE,
        ]

        for col in cols_to_summarize:
            for bldg_type, bldg_type_ts_df in df.groupby(self.BLDG_TYPE, observed=True):
                # Group as specified
                group_ts_dfs = {}
                for group_by in group_bys:
                    if group_by is None:
                        # No group-by
                        group_ts_dfs[None] = bldg_type_ts_df
                    else:
                        # With group-by
                        for group, group_ts_df in bldg_type_ts_df.groupby(group_by, observed=True):
                            group_ts_dfs[group] = group_ts_df

                # Plot a histogram for each group
                for group, group_ts_df in group_ts_dfs.items():
                    # Create a common bin size and count to use for both datasets
                    min_eui = group_ts_df[col].min()
                    max_eui = group_ts_df[col].max()
                    # max_eui = group_ts_df[col].quantile(0.9)  # Could use 90th percentile to trim tails if desired
                    n_bins = 100
                    bin_size = (max_eui - min_eui) / n_bins
                    logger.debug(f'bldg_type: {bldg_type}, min_eui: {min_eui}, max_eui: {max_eui}, n_bins: {n_bins}, bin_size: {bin_size}')

                    # Make the histogram
                    for dataset, dataset_ts_df in group_ts_df.groupby(column_for_grouping, observed=True):
                        euis = dataset_ts_df[col]
                        n_samples = len(euis)

                        # Select the color for this dataset
                        ds_color = color_map[dataset]

                        # Weight each sample by the fraction of total sqft it represents, NOT by the fraction of the building count it represents
                        wts = dataset_ts_df[self.col_name_to_weighted(self.FLR_AREA)] / dataset_ts_df[self.col_name_to_weighted(self.FLR_AREA)].sum()
                        n, bins, barcontainer = plt.hist(euis, weights=wts, range=(min_eui, max_eui), bins=n_bins, alpha=0.75, label=f'{dataset}, n={n_samples}', color=ds_color)

                        # Calculate the area-weighted mean
                        mean_eui = (euis * wts).sum()
                        plt.axvline(x=mean_eui, ymin=0, ymax=0.02,  alpha=1, ls = '', marker = 'd', mec='black', ms=10, label=f'{dataset} Mean', color=ds_color)

                    # Extract the units from the column name
                    units = self.nice_units(self.units_from_col_name(col))

                    # Titles and axis labels
                    col_title = self.col_name_to_nice_name(col)
                    col_title = col_title.replace('Normalized Annual ', '')
                    fuel = self.col_name_to_fuel(col_title)
                    if group is None:
                        # No group-by
                        title = f"Distribution of {col_title}\n for {bldg_type.replace('_', ' ')}".title()
                    else:
                        # With group-by
                        title = f"Distribution of {col_title}\n for {bldg_type.replace('_', ' ')} in {f'{group}'}".title()

                    plt.xlabel(f'{fuel} EUI ({units})\nbin size = {round(bin_size, 1)}')
                    plt.ylabel('Area-weighted fraction')
                    plt.legend()

                    # Save figure
                    title = title.replace('\n', '')
                    fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                    fig_name = fig_name.replace('distribution_of_', 'dist_')
                    fig_sub_dir = os.path.abspath(os.path.join(output_dir, bldg_type))
                    if not os.path.exists(fig_sub_dir):
                        os.makedirs(fig_sub_dir)
                    fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
                    plt.savefig(fig_path, bbox_inches = 'tight')
                    plt.cla()
                    plt.close()

    def plot_eui_boxplots_by_building_type(self, df, column_for_grouping, color_map, output_dir):
        # EUI box plot comparisons by building type and several disaggregations

        # Columns to summarize
        cols_to_summarize = [
            self.col_name_to_eui(self.ANN_TOT_ENGY_KBTU),
            self.col_name_to_eui(self.ANN_TOT_ELEC_KBTU),
            self.col_name_to_eui(self.ANN_TOT_GAS_KBTU),
        ]

        # Disaggregate to these levels
        group_bys = [
            None,
            self.CEN_DIV,
            # self.FLR_AREA_CAT, TODO reenable after adding to both CBECS and ComStock
            # self.VINTAGE,
        ]
        logger.info('Weighting DF for Building Type EUI boxplots this can take a while')

        weighted_df = df.copy()
        # Expand the dataframe according to building weights using stochastic rounding
        weighted_df = weighted_df.loc[
            weighted_df.index.repeat(
                (np.floor(weighted_df[self.BLDG_WEIGHT]) +
                (np.random.random(len(weighted_df)) <
                (weighted_df[self.BLDG_WEIGHT] - np.floor(weighted_df[self.BLDG_WEIGHT]))).astype(int)
                ).astype(int)
            )
        ].reset_index(drop=True)

        for col in cols_to_summarize:
            for bldg_type, bldg_type_ts_df in weighted_df.groupby(self.BLDG_TYPE, observed=True):

                # Make a plot for each group
                for group_by in group_bys:
                    if group_by is None:
                        # No group-by
                        g = sns.catplot(
                            data=bldg_type_ts_df,
                            y=column_for_grouping,
                            hue=column_for_grouping,
                            x=col,
                            order=list(color_map.keys()),
                            palette=color_map.values(),
                            kind='box',
                            aspect=5,
                            height=3,
                            orient='h',
                            showfliers=False,
                            showmeans=True,
                            meanprops={"marker":"d",
                                "markerfacecolor":"yellow",
                                "markeredgecolor":"black",
                                "markersize":"8"
                            },
                            legend=False,
                            dodge=False
                        )
                    else:
                        # With group-by
                        g = sns.catplot(
                            data=bldg_type_ts_df,
                            x=col,
                            hue=column_for_grouping,
                            y=group_by,
                            order=self.ORDERED_CATEGORIES[group_by],
                            hue_order=list(color_map.keys()),
                            palette=color_map.values(),
                            kind='box',
                            aspect=5,
                            height=3,
                            orient='h',
                            showfliers=False,
                            showmeans=True,
                            meanprops={"marker":"d",
                                "markerfacecolor":"yellow",
                                "markeredgecolor":"black",
                                "markersize":"8"
                            },
                        )
                        g._legend.set_title(self.col_name_to_nice_name(column_for_grouping))

                    fig = g.figure

                    # Extract the units from the column name
                    units = self.nice_units(self.units_from_col_name(col))

                    # Titles and axis labels
                    col_title = self.col_name_to_nice_name(col)
                    # col_title = col.replace(f' {units}', '')
                    # col_title = col_title.replace('Normalized Annual ', '')
                    fuel = self.col_name_to_fuel(col_title)

                    # Formatting
                    if group_by is None:
                        # No group-by
                        title = f"Boxplot of {col_title}\n for {bldg_type.replace('_', ' ')}".title()
                        for ax in g.axes.flatten():
                            ax.set_xlabel(f'{fuel} EUI ({units})')
                            ax.set_ylabel('')
                    else:
                        # With group-by
                        gb = self.col_name_to_nice_name(group_by)
                        title = f"Boxplot of {col_title}\n for {bldg_type.replace('_', ' ')} by {f'{gb}'}".title()
                        for ax in g.axes.flatten():
                            ax.set_xlabel(f'{fuel} EUI ({units})')
                            ax.set_ylabel(f'{gb}')

                    # Save figure
                    title = title.replace('\n', '')
                    fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                    fig_name = fig_name.replace('boxplot_of_', 'bp_')
                    fig_name = fig_name.replace('total_energy_consumption_', '')
                    fig_sub_dir = os.path.abspath(os.path.join(output_dir, bldg_type))
                    if not os.path.exists(fig_sub_dir):
                        os.makedirs(fig_sub_dir)
                    fig_path = os.path.abspath((os.path.join(fig_sub_dir, fig_name)))
                    plt.savefig(fig_path)
                    plt.close()

    def plot_measure_savings_distributions_by_building_type(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.BLDG_TYPE

        # energy column
        en_col = self.ANN_TOT_ENGY_KBTU

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].drop_duplicates().astype(str)), reverse=True)

        # make lists of columns; these savings columns should exist in dataframe
        # enduse
        dict_saving = {}
        li_eui_svgs_btype = self.col_name_to_savings(self.col_name_to_eui(en_col))
        dict_saving['Site EUI Savings by Building Type (kBtu/ft<sup>2</sup>)'] = li_eui_svgs_btype
        li_pct_svgs_btype = self.col_name_to_percent_savings(en_col, 'percent')
        dict_saving['Percent Site Energy Savings by Building Type (%)'] = li_pct_svgs_btype

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=16, title=group_name)
            fig.update_yaxes(mirror=True, showgrid=True, type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name = fig_name.replace('_total_energy_consumption', '')
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'savings_distributions'))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            self.queue_figure(fig, fig_path, scale=10)

        return

    def plot_measure_utility_savings_distributions_by_building_type(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.BLDG_TYPE

        # energy column
        en_col = self.UTIL_BILL_TOTAL_MEAN

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].drop_duplicates().astype(str)), reverse=True)

        # create dictionary with the plot labels and columns to loop through
        dict_saving = {}
        dict_saving['Utility Bill Savings Intensity by Building Type (usd/sqft/year, 2022)'] = self.col_name_to_savings(self.col_name_to_area_intensity(en_col))
        dict_saving['Percent Utility Bill Savings by Building Type (%)'] = self.col_name_to_percent_savings(self.col_name_to_weighted(en_col), 'percent')

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=20, title=group_name)
            fig.update_yaxes(mirror=True, showgrid=True, type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name = fig_name.replace(r'_(usd/sqft/year,', '')
            fig_sub_dir = os.path.join(output_dir, 'savings_distributions')
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.join(fig_sub_dir, fig_name)
            self.queue_figure(fig, fig_path, scale=10)

        return

    def plot_measure_utility_savings_distributions_by_climate_zone(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.CZ_ASHRAE

        # energy column
        en_col = self.UTIL_BILL_TOTAL_MEAN

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].drop_duplicates().astype(str)), reverse=True)

        # create dictionary with the plot labels and columns to loop through
        dict_saving = {}
        dict_saving['Utility Bill Savings Intensity by Climate (usd/sqft/year, 2022)'] = self.col_name_to_savings(self.col_name_to_area_intensity(en_col))
        dict_saving['Percent Utility Bill Savings by Climate (%)'] = self.col_name_to_percent_savings(self.col_name_to_weighted(en_col), 'percent')

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=20, title=group_name)
            fig.update_yaxes(mirror=True, showgrid=True, type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name = fig_name.replace(r'_(usd/sqft/year,', '')
            fig_sub_dir = os.path.join(output_dir, 'savings_distributions')
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.join(fig_sub_dir, fig_name)
            self.queue_figure(fig, fig_path, scale=10)

        return

    def plot_measure_utility_savings_distributions_by_hvac_system(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.HVAC_SYS

        # energy column
        en_col = self.UTIL_BILL_TOTAL_MEAN

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].drop_duplicates().astype(str)), reverse=True)

        # create dictionary with the plot labels and columns to loop through
        dict_saving = {}
        dict_saving['Utility Bill Savings Intensity by HVAC (usd/sqft/year, 2022)'] = self.col_name_to_savings(self.col_name_to_area_intensity(en_col))
        dict_saving['Percent Utility Bill Savings by HVAC (%)'] = self.col_name_to_percent_savings(self.col_name_to_weighted(en_col), 'percent')

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=20, title=group_name)
            fig.update_yaxes(mirror=True, showgrid=True, type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name = fig_name.replace(r'_(usd/sqft/year,', '')
            fig_sub_dir = os.path.join(output_dir, 'savings_distributions')
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.join(fig_sub_dir, fig_name)
            self.queue_figure(fig, fig_path, scale=10)

        return

    def plot_measure_savings_distributions_by_climate_zone(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.CZ_ASHRAE

        # energy column
        en_col = self.ANN_TOT_ENGY_KBTU

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].unique().astype(str)), reverse=True)

        # make lists of columns; these savings columns should exist in dataframe
        # enduse
        dict_saving = {}
        li_eui_svgs_btype = self.col_name_to_savings(self.col_name_to_eui(en_col))
        dict_saving['Site EUI Savings by Climate Zone (kBtu/ft<sup>2</sup>)'] = li_eui_svgs_btype
        li_pct_svgs_btype = self.col_name_to_percent_savings(en_col, 'percent')
        dict_saving['Percent Site Energy Savings by Climate Zone (%)'] = li_pct_svgs_btype

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI metrics
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=16, title=group_name)
            fig.update_yaxes(mirror=True, showgrid=True, type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'savings_distributions'))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            self.queue_figure(fig, fig_path, scale=10)

        return

    def plot_measure_savings_distributions_by_hvac_system_type(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[0]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[0]

        # group column
        col_group = self.HVAC_SYS

        # energy column
        en_col = self.ANN_TOT_ENGY_KBTU

        # set grouping list
        li_group = sorted(list(df_upgrade[col_group].drop_duplicates().astype(str)), reverse=True)

        # make lists of columns; these savings columns should exist in dataframe
        # enduse
        dict_saving = {}
        li_eui_svgs_btype = self.col_name_to_savings(self.col_name_to_eui(en_col))
        dict_saving['Site EUI Savings by HVAC System (kBtu/ft<sup>2</sup>)'] = li_eui_svgs_btype
        li_pct_svgs_btype = self.col_name_to_percent_savings(en_col, 'percent')
        dict_saving['Percent Site Energy Savings by HVAC System (%)'] = li_pct_svgs_btype

        # # loop through plot types
        for group_name, energy_col in dict_saving.items():

            # remove unit from group_name
            group_name_wo_unit = group_name.rsplit(" ", 1)[0]

            # filter to group and energy column
            df_upgrade_plt = df_upgrade.loc[:, [col_group, energy_col]]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade_plt, 100)

            # create figure template
            fig = go.Figure()

            # loop through groups, i.e. building type etc.
            for group in li_group:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[energy_col]!=0) & (df_upgrade_plt[energy_col].notna()) & ((df_upgrade_plt[col_group]==group)), energy_col]

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(group),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(group) + f' (n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = group_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=16, title=group_name, automargin=True)
            fig.update_yaxes(mirror=True, showgrid=True, nticks=len(li_group), type='category', dtick=1, automargin=True)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'savings_distributions'))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            self.queue_figure(fig, fig_path, scale=10)


        return

    def plot_measure_savings_distributions_enduse_and_fuel(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling;
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[1]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[1]

        # make lists of columns; these savings columns should exist in dataframe
        # enduse
        dict_saving = {}
        li_eui_svgs_enduse_cols = [self.col_name_to_savings(self.col_name_to_eui(c)) for c in self.COLS_ENDUSE_ANN_ENGY]
        dict_saving['Site EUI Savings by End Use (kBtu/ft<sup>2</sup>)'] = li_eui_svgs_enduse_cols
        li_pct_svgs_enduse_cols = [self.col_name_to_percent_savings(c, 'percent') for c in self.COLS_ENDUSE_ANN_ENGY]
        dict_saving['Percent Site Energy Savings by End Use (%)'] = li_pct_svgs_enduse_cols
        # fuel
        li_eui_svgs_fuel_cols = [self.col_name_to_savings(self.col_name_to_eui(c)) for c in self.COLS_TOT_ANN_ENGY]
        dict_saving['Site EUI Savings by Fuel (kBtu/ft<sup>2</sup>)'] = li_eui_svgs_fuel_cols
        li_pct_svgs_fuel_cols = [self.col_name_to_percent_savings(c, 'percent') for c in self.COLS_TOT_ANN_ENGY]
        dict_saving['Percent Site Energy Savings by Fuel (%)'] = li_pct_svgs_fuel_cols

        # loop through plot types
        for savings_name, col_list in dict_saving.items():


            # remove unit from savings_name
            savings_name_wo_unit = savings_name.rsplit(" ", 1)[0]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade[col_list], 150)

            # create figure template
            fig = go.Figure()

            # loop through enduses
            for enduse_col in col_list:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[enduse_col]!=0) & (df_upgrade_plt[enduse_col].notna()), enduse_col]

                # column name
                col_name = self.col_name_to_nice_saving_name(df_enduse.name)

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(col_name),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(col_name) + f'(n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = savings_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=16, title=savings_name)
            fig.update_yaxes(mirror=True, showgrid=True, nticks=len(li_pct_svgs_enduse_cols), type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'savings_distributions'))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            self.queue_figure(fig, fig_path, scale=10)


    ######
    def plot_measure_utility_savings_distributions_by_fuel(self, df, output_dir):

        # remove baseline; not needed
        df_upgrade = df.loc[df[self.UPGRADE_ID]!=0, :]

        # get upgrade name and id for labeling;
        upgrade_num = df_upgrade[self.UPGRADE_ID].iloc[1]
        upgrade_name = df_upgrade[self.UPGRADE_NAME].iloc[1]

        # make lists of columns; these savings columns should exist in dataframe
        dict_saving = {}
        li_eui_svgs_fuel_cols = [self.col_name_to_savings(self.col_name_to_area_intensity(c)) for c in ([self.UTIL_BILL_TOTAL_MEAN] + self.COLS_UTIL_BILLS)]
        dict_saving['Utility Bill Savings Intensity by Fuel (usd/sqft/year, 2022)'] = li_eui_svgs_fuel_cols
        li_pct_svgs_fuel_cols = [self.col_name_to_percent_savings(self.col_name_to_weighted(c), 'percent') for c in ([self.UTIL_BILL_TOTAL_MEAN] + self.COLS_UTIL_BILLS)]
        dict_saving['Percent Utility Bill Savings by Fuel (%)'] = li_pct_svgs_fuel_cols

        # loop through plot types
        for savings_name, col_list in dict_saving.items():

            # remove unit from savings_name
            savings_name_wo_unit = savings_name.rsplit(" ", 1)[0]

            # apply method for filtering percent savings; this will not affect EUI
            df_upgrade_plt = self.filter_outlier_pct_savings_values(df_upgrade[col_list], 150)

            # create figure template
            fig = go.Figure()

            # loop through enduses
            for enduse_col in col_list:

                # get data for enduse; remove 0s and na values
                df_enduse = df_upgrade_plt.loc[(df_upgrade_plt[enduse_col]!=0) & (df_upgrade_plt[enduse_col].notna()), enduse_col]

                # column name
                col_name = self.col_name_to_nice_saving_name(df_enduse.name)
                # manually add "total"
                col_name = col_name.replace('Utility Bills Mean Bill Intensity', 'Utility Bills Total Bill Intensity')
                col_name = col_name.replace('Bill Intensity', 'Bill Intensity')
                col_name = col_name.replace('Utility Bills ', '')
                col_name = col_name.replace('Electricity Bill', 'Electricity Bill w/ Mean Rate')
                col_name = col_name.replace('Total Bill', 'Total Bill w/ Mean Electricity Rate')
                col_name = col_name.replace('Mean Bill', 'Total Bill w/ Mean Electricity Rate')
                col_name = col_name.replace('Mean Rate Mean', 'Mean Rate')
                col_name = col_name.replace(' Intensity', '')

                # add traces to plot
                fig.add_trace(go.Violin(
                    x=df_enduse,
                    y=np.array(col_name),
                    orientation = 'h',
                    box_visible=True,
                    points='outliers',
                    pointpos=1,
                    spanmode='hard',
                    marker_size=1,
                    showlegend=False,
                    name=str(col_name) + f'(n={len(df_enduse)})',
                    meanline_visible=True,
                    line=dict(width=0.7),
                    fillcolor=color_violin,
                    box_fillcolor=color_interquartile,
                    line_color='black',
                    width=0.95
                ))

            fig.add_annotation(
                align="right",
                font_size=12,
                showarrow=False,
                text=f"Upgrade {str(upgrade_num).zfill(2)}: {upgrade_name} (unweighted)",
                x=1,
                xanchor="right",
                xref="x domain",
                y=1.01,
                yanchor="bottom",
                yref="y domain",
            )

            title = savings_name_wo_unit
            # formatting and saving image
            fig.update_layout(template='simple_white', margin=dict(l=20, r=20, t=20, b=20), width=800)
            fig.update_xaxes(mirror=True, showgrid=True, zeroline=True, nticks=16, title=savings_name)
            fig.update_yaxes(mirror=True, showgrid=True, nticks=len(li_pct_svgs_fuel_cols), type='category', dtick=1)
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name = fig_name.replace(r'_(usd/sqft/year,', '')
            fig_sub_dir = os.path.join(output_dir, 'savings_distributions')
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.join(fig_sub_dir, fig_name)
            self.queue_figure(fig, fig_path, scale=10)


    ######

    def plot_qoi_timing(self, df, column_for_grouping, color_map, output_dir):

        qoi_timing = self.QOI_MAX_DAILY_TIMING_COLS

        short_names = []
        for col_name in qoi_timing:
            col_name = self.shorten_qoi_names(col_name)
            short_names.append(col_name)

        violin_qoi_timing = px.violin(
            data_frame = df,
            x = qoi_timing,
            orientation = 'h',
            box = True,
            points = 'outliers',
            color = column_for_grouping,
            color_discrete_sequence = list(color_map.values()),
            violinmode = "group",
            template='simple_white'
        )

        # formatting and saving image
        title="maximum_daily_peak_timing_hr"
        violin_qoi_timing.update_yaxes(mirror=True, title="Season", tickmode = "array", ticktext =short_names, tickvals=qoi_timing)
        violin_qoi_timing.update_xaxes(mirror=True, title="Maximum Daily Peak Timing by Season (Hour of Day)")
        violin_qoi_timing.update_layout(
            legend_title = self.col_name_to_nice_name(column_for_grouping),
            margin=dict(l=5, r=5, t=5, b=5),
            )
        fig_name = f'{title}.{self.image_type}'
        fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'qoi_distributions'))
        if not os.path.exists(fig_sub_dir):
            os.makedirs(fig_sub_dir)
        fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
        self.queue_figure(violin_qoi_timing, fig_path, scale=10)

    def plot_qoi_max_use(self, df, column_for_grouping, color_map, output_dir):

        max_use_cols_normalized = self.QOI_MAX_USE_COLS_NORMALIZED

        short_names = []
        for col_name in max_use_cols_normalized:
            col_name = self.shorten_qoi_names(col_name)
            short_names.append(col_name)

        violin_qoi_timing = px.violin(
            data_frame = df,
            x = max_use_cols_normalized,
            orientation = 'h',
            box = True,
            points = 'outliers',
            color = column_for_grouping,
            color_discrete_sequence = list(color_map.values()),
            violinmode = "group",
            template='simple_white'
        )

        # formatting and saving image
        title="maximum_daily_peak_magnitude_w_ft2"
        violin_qoi_timing.update_yaxes(mirror=True, title="Season",  tickmode = "array", ticktext =short_names, tickvals=max_use_cols_normalized)
        violin_qoi_timing.update_xaxes(mirror=True, title="Maximum Daily Peak Magnitude by Season (W/ft<sup>2</sup>)")
        violin_qoi_timing.update_layout(
            legend_title = self.col_name_to_nice_name(column_for_grouping),
            margin=dict(l=5, r=5, t=5, b=5),
            )
        fig_name = f'{title}.{self.image_type}'
        fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'qoi_distributions'))
        if not os.path.exists(fig_sub_dir):
            os.makedirs(fig_sub_dir)
        fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
        self.queue_figure(violin_qoi_timing, fig_path, scale=10)

    def plot_qoi_min_use(self, df, column_for_grouping, color_map, output_dir):

        min_use_cols_normalized = self.QOI_MIN_USE_COLS_NORMALIZED

        short_names = []
        for col_name in min_use_cols_normalized:
            col_name = self.shorten_qoi_names(col_name)
            short_names.append(col_name)

        violin_qoi_timing = px.violin(
            data_frame = df,
            x = min_use_cols_normalized,
            orientation = 'h',
            box = True,
            points = 'outliers',
            color = column_for_grouping,
            color_discrete_sequence = list(color_map.values()),
            violinmode = "group",
            template='simple_white'
        )

        # formatting and saving image
        title="minimum_daily_peak_magnitude_w_ft2"
        violin_qoi_timing.update_yaxes(mirror=True, title="Season", tickmode="array", ticktext=short_names, tickvals=min_use_cols_normalized)
        violin_qoi_timing.update_xaxes(mirror=True, title="Minimum Daily Peak Magnitude by Season (W/ft<sup>2</sup>)")
        violin_qoi_timing.update_layout(
            legend_title = self.col_name_to_nice_name(column_for_grouping),
            margin=dict(l=5, r=5, t=5, b=5),
            )
        fig_name = f'{title}.{self.image_type}'
        fig_sub_dir = os.path.abspath(os.path.join(output_dir, 'qoi_distributions'))
        if not os.path.exists(fig_sub_dir):
            os.makedirs(fig_sub_dir)
        fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
        self.queue_figure(violin_qoi_timing, fig_path, scale=10)


    def plot_unmet_hours(self, df, column_for_grouping, color_map, output_dir):

        # get applicable buildings
        li_applic_blgs = df.loc[(df[self.UPGRADE_NAME] != 'Baseline') & (df['applicability']==1), self.BLDG_ID].unique().tolist()
        df_applic = df.loc[df[self.BLDG_ID].isin(li_applic_blgs), :]

        # Define colors for heating and cooling
        colors = {"heating": "red", "cooling": "blue"}

        # Create subplots (1 row, 2 columns)
        fig = make_subplots(rows=1, cols=2, shared_yaxes=True, subplot_titles=["Heating Unmet Hours", "Cooling Unmet Hours"])

        # Loop through heating and cooling unmet hours
        for i, mode in enumerate(self.UNMET_HOURS_COLS):
            mode_name = mode.split(".")[2]  # Extract readable title
            color = colors["heating"] if "heating" in mode.lower() else colors["cooling"]
            col_num = 1 if "heating" in mode.lower() else 2

            # Add box plot - total distribution
            fig.add_trace(
                go.Box(
                    x=df_applic[mode],
                    y=df_applic[self.UPGRADE_NAME],
                    marker=dict(color=color),
                    boxpoints='outliers',
                    marker_size=1,
                    pointpos=1,
                    name=mode_name,
                    orientation="h"
                ),
                row=1, col=col_num
            )

        # Apply log scale to x-axes
        fig.update_xaxes(title_text="Unmet Hours Count",
                         showgrid=True,
                         range=[0,4],
                         nticks=14,
                         exponentformat = 'power',
                         tickfont=dict(size=8),
                         mirror=True,
                         type="log",
                         row=1, col=1)
        fig.update_xaxes(title_text="Unmet Hours Count",
                         showgrid=True,
                         range=[0,4],
                         nticks=14,
                         exponentformat = 'power',
                         tickfont=dict(size=8),
                         mirror=True,
                         type="log",
                         row=1, col=2)

        # Update y-axis labels
        fig.update_yaxes(mirror=True, row=1, col=1)
        fig.update_yaxes(mirror=True, row=1, col=2)  # Hide y-axis label for second subplot title_text="",

        # Adjust layout
        fig.update_layout(
            template="simple_white",
            showlegend=False,
            height=300,
            margin=dict(l=20, r=20, t=20, b=20)
        )

        # Save the figure
        title = "unmet_hours"
        fig_name = f'{title}.{self.image_type}'
        fig_name_html = f'{title.replace(" ", "_").lower()}.html'
        fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
        fig_path_html = os.path.abspath(os.path.join(output_dir, fig_name_html))
        self.queue_figure(fig, fig_path, scale=10)
        #fig.write_html(fig_path_html)

        return fig

    def filter_outlier_pct_savings_values(self, df, max_percentage_change):

        # get applicable columns
        cols = df.loc[:, df.columns.str.contains('percent_savings')].columns

        # make copy of dataframe
        df_2 = df.copy()

        # filter out data that falls outside of user-input range by changing them to nan
        # when plotting, nan values will be skipped
        df_2.loc[:, cols] = df_2[cols].mask(df[cols]>max_percentage_change, np.nan)
        df_2.loc[:, cols] = df_2[cols].mask(df[cols]<-max_percentage_change, np.nan)

        # filter out % savings values greater than 100%
        df_2.loc[:, cols] = df_2[cols].mask(df_2[cols] > 100, np.nan)

        return df_2

    def plot_annual_energy_consumption_for_eia(self, df, color_map, output_dir):
         # Summarize annual energy consumption for EIA plots

       # Columns to summarize
        cols_to_summarize = {
            'Electricity consumption (kWh)': 'sum',
            'Natural gas consumption (thous Btu)': 'sum'
        }

        # Disaggregate to these levels
        group_bys = [
            None,
            self.STATE_ABBRV,
            'Division'
        ]

        for col, agg_method in cols_to_summarize.items():
            for group_by in group_bys:
                # Summarize the data
                vals = [col]  # Values in Excel pivot table
                ags = [agg_method]  # How each of the values will be aggregated, like Value Field Settings in Excel, but applied to all values
                cols = [self.DATASET] # Columns in Excel pivot table

                first_ax = None

                if group_by is None:
                    # No group-by
                    pivot = df.pivot_table(values=vals, columns=cols, aggfunc=ags)
                    pivot = pivot.droplevel([0], axis=1)
                else:
                    # With group-by
                    idx = [group_by]  # Rows in Excel pivot table
                    pivot = df.pivot_table(values=vals, columns=cols, index=idx, aggfunc=ags)
                    pivot = pivot.droplevel([0, 1], axis=1)

                # Make the graph
                if first_ax is None:
                    ax = pivot.plot.bar(color=color_map)
                    first_ax = ax
                else:
                    ax = pivot.plot.bar(color=color_map, ax=first_ax)

                # Extract the units from the column name
                match = re.search('\\(.*\\)', col)
                if match:
                    units = match.group(0)
                else:
                    units = 'TODO units'

                # Formatting
                if group_by is None:
                    # No group-by]
                    title = f"{agg_method} {col.replace(f' {units}', '')}".title()
                    ax.tick_params(axis='x', labelrotation = 0)
                    for container in ax.containers:
                        ax.bar_label(container, fmt='%.2e')
                else:
                    # With group-by
                    title = f"{agg_method} {col.replace(f' {units}', '')}\n by {group_by}".title()

                # Remove 'Sum' from title
                title = title.replace('Sum', '').strip()

                # Set title and units
                ax.set_title(title)
                ax.set_ylabel(f'Annual Energy Consumption {units}')

                # Add legend with no duplicate entries
                handles, labels = first_ax.get_legend_handles_labels()
                new_labels = []
                new_handles = []
                for l, h in zip(labels, handles):
                    if not l in new_labels:
                        new_labels.append(l)  # Add the first instance of the label
                        new_handles.append(h)
                ax.legend(new_handles, new_labels, bbox_to_anchor=(1.01,1), loc="upper left")

                # Save the figure
                title = title.replace('\n', '')
                fig_name = f'com_eia_{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                plt.savefig(fig_path, bbox_inches = 'tight')
                plt.close()


    def plot_monthly_energy_consumption_for_eia(self, df, color_map, output_dir):
        # Columns to summarize
        cols_to_summarize = {
            'Electricity consumption (kWh)': 'sum',
            'Natural gas consumption (thous Btu)': 'sum'
        }

        # Disaggregate to these levels
        group_bys = [
            self.STATE_ABBRV,
            'Division'
        ]

        for col, agg_method in cols_to_summarize.items():
            for group_by in group_bys:
                # Summarize the data
                vals = [col]  # Values in Excel pivot table
                ags = [agg_method]  # How each of the values will be aggregated, like Value Field Settings in Excel, but applied to all values
                cols = [self.DATASET] # Columns in Excel pivot table


                for group_name, group_data in df.groupby(group_by, observed=True):

                    # With group-by
                    pivot = group_data.pivot_table(values=vals, columns=cols, index='Month', aggfunc=ags)
                    pivot = pivot.droplevel([0, 1], axis=1)

                    # Make the graph
                    ax = pivot.plot.bar(color=color_map)

                    # Extract the units from the column name
                    match = re.search('\\(.*\\)', col)
                    if match:
                        units = match.group(0)
                    else:
                        units = 'TODO units'

                    # Set title and units
                    title = f"{agg_method} Monthly {col.replace(f' {units}', '')}\n by {group_by} for {group_name}".title()

                    # Remove 'Sum' from title
                    title = title.replace('Sum', '').strip()

                    ax.set_title(title)
                    ax.set_ylabel(f'Monthly Energy Consumption {units}')

                    # Add legend with no duplicate entries
                    handles, labels = ax.get_legend_handles_labels()
                    new_labels = []
                    new_handles = []
                    for l, h in zip(labels, handles):
                        if not l in new_labels:
                            new_labels.append(l)  # Add the first instance of the label
                            new_handles.append(h)
                    ax.legend(new_handles, new_labels, bbox_to_anchor=(1.01,1), loc="upper left")

                    # Save the figure
                    title = title.replace('\n', '')
                    fig_name = f'com_eia_{title.replace(" ", "_").lower()}.{self.image_type}'
                    fig_path = os.path.abspath(os.path.join(output_dir, fig_name))
                    plt.savefig(fig_path, bbox_inches = 'tight')
                    plt.close()


    # color functions from https://bsouthga.dev/posts/color-gradients-with-python
    def linear_gradient(self, start_hex, finish_hex="#FFFFFF", n=10):
        ''' returns a gradient list of (n) colors between
            two hex colors. start_hex and finish_hex
            should be the full six-digit color string,
            inlcuding the number sign ("#FFFFFF") '''
        # Starting and ending colors in RGB for
        s = self.hex_to_RGB(start_hex)
        f = self.hex_to_RGB(finish_hex)
        # Initilize a list of the output colors with the starting color
        RGB_list = [s]
        # Calcuate a color at each evenly spaced value of t from 1 to n
        for t in range(1, n):
            # Interpolate RGB vector for color at the current value of t
            curr_vector = [
            int(s[j] + (float(t)/(n-1))*(f[j]-s[j]))
            for j in range(3)
            ]
            # Add it to our list of output colors
            RGB_list.append(curr_vector)

        hex_list = [self.RGB_to_hex(color) for color in RGB_list]
        color_dict = {'hex': hex_list}

        return color_dict

    def color_dict(self, gradient):
        ''' Takes in a list of RGB sub-lists and returns dictionary of
            colors in RGB and hex form for use in a graphing function
            defined later on '''
        return {"hex":[self.RGB_to_hex(RGB) for RGB in gradient],
            "r":[RGB[0] for RGB in gradient],
            "g":[RGB[1] for RGB in gradient],
            "b":[RGB[2] for RGB in gradient]}

    def hex_to_RGB(self, hex):
        ''' "#FFFFFF" -> [255,255,255] '''
        # Pass 16 to the integer function for change of base
        return [int(hex[i:i+2], 16) for i in range(1,6,2)]

    def RGB_to_hex(self, RGB):
        ''' [255,255,255] -> "#FFFFFF" '''
        # Components need to be integers for hex to make sense
        RGB = [int(x) for x in RGB]
        return "#"+"".join(["0{0:x}".format(v) if v < 16 else
                    "{0:x}".format(v) for v in RGB])


    """
    Seasonal load stacked area plots by daytype (weekday and weekdend) comparison
    Args:
        df: long form dataset with a comstock run and ami data
        region: region object from AMI class
        building_type (str): building type
        color_map: hash with dataset names as the keys
        output_dir (str): output directory
        normalization (str): how to normalize the data. Default is 'None' which directly compares kwh_per_sf. Other options are 'Annual' and 'Daytype'. 'Annual' will normalize the data as a fraction compared to the total annual energy use. 'Daytype' will normalize to the energy use for the given day type.
        save_graph_data (bool): set to true to save graph data
    """
    def plot_day_type_comparison_stacked_by_enduse(self, df, region, building_type, color_map, output_dir, normalization='None', save_graph_data=False):
        summer_months = region['summer_months']
        winter_months = region['winter_months']
        shoulder_months = region['shoulder_months']

        enduse_list = [
            'exterior_lighting',
            'interior_lighting',
            'interior_equipment',
            'exterior_equipment',
            'water_systems',
            'heat_recovery',
            'fans',
            'pumps',
            'heat_rejection',
            'humidification',
            'cooling',
            'heating',
            'refrigeration'
        ]

        enduse_colors = [
            '#DEC310',  # exterior lighting
            '#F7DF10',  # interior lighting
            '#4A4D4A',  # interior equipment
            '#B5B2B5',  # exterior equipment
            '#FFB239',  # water systems
            '#CE5921',  # heat recovery
            '#FF79AD',  # fans
            '#632C94',  # pumps
            '#F75921',  # heat rejection
            '#293094',  # humidification
            '#0071BD',  # cooling
            '#EF1C21',  # heating
            '#29AAE7'   # refrigeration
        ]

        comstock_data_label = list(color_map.keys())[0]
        ami_data_label = list(color_map.keys())[1]
        energy_column = 'kwh_per_sf'
        default_uncertainty = 0.1

        # filter and collect comstock data
        comstock_data = df.loc[df.run.isin([comstock_data_label])]
        comstock_count = comstock_data['bldg_count']
        comstock_count_max = int(comstock_count.max())
        comstock_count_avg = comstock_count.mean()
        comstock_count_min = int(comstock_count.min())
        comstock_data = comstock_data[['enduse', energy_column]]
        comstock_data = comstock_data.reset_index().groupby(['enduse', 'timestamp'], observed=True).sum().reset_index().set_index('timestamp')
        comstock_data = comstock_data.pivot(columns='enduse', values=[energy_column])
        comstock_data.columns = comstock_data.columns.droplevel(0)
        comstock_data = comstock_data.reset_index().rename_axis(None, axis=1)
        comstock_data = comstock_data.set_index('timestamp')
        comstock_data = comstock_data.head(8760)
        if normalization == 'Annual':
          comstock_annual_total = comstock_data['total'].sum()
          comstock_data = comstock_data / comstock_annual_total

        # Remove missing enduses from enduse list and enduse colors before plotting
        filtered_enduse_list = [col for col in enduse_list if col in comstock_data.columns]
        filtered_enduse_colors = [enduse_colors[i] for i, col in enumerate(enduse_list) if col in comstock_data.columns]

        # filter and collect ami data
        ami_data = df.loc[df.run.isin([ami_data_label])]
        ami_count = ami_data['bldg_count']
        ami_count_max = int(ami_count.max())
        ami_count_avg = ami_count.mean()
        ami_count_min = int(ami_count.min())
        ami_data = ami_data[['run', energy_column]]
        ami_data = ami_data.pivot(columns='run', values=[energy_column])
        ami_data.columns = ami_data.columns.droplevel(0)
        ami_data = ami_data.reset_index().rename_axis(None, axis=1)
        ami_data = ami_data.set_index('timestamp')
        ami_data = ami_data.head(8760)
        if normalization == 'Annual':
          ami_annual_total = ami_data.sum()
          ami_data = ami_data / ami_annual_total

        # Assign sample uncertainty
        total_data = df.loc[df.enduse.isin(['total'])]
        try:
            sample_uncertainty = total_data.loc[total_data.run.isin([ami_data_label])][['sample_uncertainty']]
        except KeyError:
            sample_uncertainty = total_data.loc[total_data.run.isin([ami_data_label])][['run', energy_column]]
            sample_uncertainty.rename(columns={energy_column: 'sample_uncertainty'}, inplace=True)
            sample_uncertainty['sample_uncertainty'] = default_uncertainty

        # comstock day type dictionary
        comstock_day_type_dict = {}
        if summer_months:
            comstock_day_type_dict.update({'Summer_Weekday': (comstock_data.index.weekday < 5)
                                    & (comstock_data.index.month.isin(summer_months))})
            comstock_day_type_dict.update({'Summer_Weekend': (comstock_data.index.weekday >= 5)
                                    & (comstock_data.index.month.isin(summer_months))})
        if winter_months:
            comstock_day_type_dict.update({'Winter_Weekday': (comstock_data.index.weekday < 5)
                                    & (comstock_data.index.month.isin(winter_months))})
            comstock_day_type_dict.update({'Winter_Weekend': (comstock_data.index.weekday >= 5)
                                    & (comstock_data.index.month.isin(winter_months))})
        if shoulder_months:
            comstock_day_type_dict.update({'Shoulder_Weekday': (comstock_data.index.weekday < 5)
                                    & (comstock_data.index.month.isin(shoulder_months))})
            comstock_day_type_dict.update({'Shoulder_Weekend': (comstock_data.index.weekday >= 5)
                                    & (comstock_data.index.month.isin(shoulder_months))})

        # ami day type dictionary
        ami_day_type_dict = {}
        if summer_months:
            ami_day_type_dict.update({'Summer_Weekday': (ami_data.index.weekday < 5)
                                    & (ami_data.index.month.isin(summer_months))})
            ami_day_type_dict.update({'Summer_Weekend': (ami_data.index.weekday >= 5)
                                    & (ami_data.index.month.isin(summer_months))})
        if winter_months:
            ami_day_type_dict.update({'Winter_Weekday': (ami_data.index.weekday < 5)
                                    & (ami_data.index.month.isin(winter_months))})
            ami_day_type_dict.update({'Winter_Weekend': (ami_data.index.weekday >= 5)
                                    & (ami_data.index.month.isin(winter_months))})
        if shoulder_months:
            ami_day_type_dict.update({'Shoulder_Weekday': (ami_data.index.weekday < 5)
                                    & (ami_data.index.month.isin(shoulder_months))})
            ami_day_type_dict.update({'Shoulder_Weekend': (ami_data.index.weekday >= 5)
                                    & (ami_data.index.month.isin(shoulder_months))})

        # plot
        plt.figure(figsize=(20, 20))
        filename = (region['source_name'] + '_' + ami_data_label.lower().replace(' ', '') + '_' + building_type)
        graph_type = ''
        if normalization == 'Annual':
            day_type_label = 'Annual Normalized'
            graph_type = "annual_normalized_day_type_comparison_by_enduse"
        elif normalization == 'Daytype':
            day_type_label = 'Day Type Normalized'
            graph_type = "daytype_normalized_day_type_comparison_by_enduse"
        else:
            day_type_label = ''
            graph_type = "day_type_comparison_by_enduse"
        plt.suptitle('{} Day Type Comparison by Enduse\n{} (n={}) vs. {} (n={})\n{}, {}'.format(day_type_label, comstock_data_label, comstock_count_max, ami_data_label, ami_count_max, region['source_name'], building_type), fontsize=24)
        filename = filename + "_" + graph_type
        plt.subplots_adjust(top=0.9)
        fig_n = 0

        ylabel_text = 'Electric Load (kwh/ft2)'
        if normalization == 'Annual':
            ylabel_text = 'Normalized (Annual Sum = 1)'
        elif normalization == 'Daytype':
            ylabel_text = 'Normalized (Day Sum = 1)'

        # calculate y_max in the plot
        y_max_buildstock = 0
        for day_type in comstock_day_type_dict.keys():
            y_max_temp = pd.DataFrame(comstock_data['total'][comstock_day_type_dict[day_type]])
            y_max_temp['hour'] = y_max_temp.index.hour
            y_max_temp = y_max_temp.groupby('hour', observed=True).mean()
            if normalization == 'Daytype':
                y_max_temp_value = float(y_max_temp['total'].max()/y_max_temp['total'].sum())
            else:
                y_max_temp_value = float(y_max_temp['total'].max())
            if y_max_temp_value > y_max_buildstock:
                y_max_buildstock = y_max_temp_value

        y_max_ami = 0
        for day_type in ami_day_type_dict.keys():
            y_max_temp = pd.DataFrame(ami_data[ami_day_type_dict[day_type]])
            y_max_temp['hour'] = y_max_temp.index.hour
            y_max_temp_value = float(y_max_temp.groupby('hour', observed=True).mean().max().iloc[0])
            if y_max_temp_value > y_max_ami:
                y_max_ami = y_max_temp_value
        y_max = max(y_max_buildstock, y_max_ami)

        plot_data_df = pd.DataFrame()
        for day_type in ami_day_type_dict.keys():
            fig_n = fig_n + 1
            ax = plt.subplot(3, 2, fig_n)
            ax.spines['top'].set_color('black')
            ax.spines['bottom'].set_color('black')
            ax.spines['right'].set_color('black')
            ax.spines['left'].set_color('black')
            plt.rcParams.update({'font.size': 16})

            # Truth data
            truth_data = pd.DataFrame(ami_data[ami_data_label][ami_day_type_dict[day_type]])
            truth_data['hour'] = truth_data.index.hour
            truth_data = truth_data.groupby('hour', observed=True).mean()
            if normalization == 'Daytype':
                truth_data_total = truth_data.sum()
                truth_data = truth_data / truth_data_total

            # Stacked Enduses Plot
            processed_data_for_stack_plot = pd.DataFrame(comstock_data[filtered_enduse_list][comstock_day_type_dict[day_type]])
            processed_data_for_stack_plot['hour'] = processed_data_for_stack_plot.index.hour
            processed_data_for_stack_plot = processed_data_for_stack_plot.groupby('hour', observed=True).mean()
            if normalization == 'Daytype':
                processed_data_total = processed_data_for_stack_plot.sum().sum()
                processed_data_for_stack_plot = processed_data_for_stack_plot / processed_data_total

            plt.stackplot(
                processed_data_for_stack_plot.index,
                processed_data_for_stack_plot.T,
                labels=filtered_enduse_list,
                colors=filtered_enduse_colors
            )

            # Truth Data Plot
            y = truth_data
            s_uncertainty = pd.DataFrame(sample_uncertainty[ami_day_type_dict[day_type]])
            s_uncertainty['hour'] = s_uncertainty.index.hour
            s_uncertainty = s_uncertainty.groupby('hour', observed=True).mean()

            # Upper Estimate
            upper_truth = pd.DataFrame(
                y[ami_data_label].values +
                y[ami_data_label].values * s_uncertainty['sample_uncertainty'].values
            )
            plt.plot(
                upper_truth,
                color='k',
                label='{}: 80% CI upper estimate'.format(ami_data_label),
                linestyle='--'
            )
            y_max = np.max([float(np.max(upper_truth)), y_max])

            # Mean Estimate
            plt.plot(
                y,
                color='k',
                label=ami_data_label
            )

            # Lower estimate
            lower_truth = pd.DataFrame(
                y[ami_data_label].values -
                y[ami_data_label].values * s_uncertainty['sample_uncertainty'].values
            )
            # values cannot be negative
            lower_truth = lower_truth.clip(lower=0)
            plt.plot(
                lower_truth,
                color='k',
                label='{}: 80% CI lower estimate'.format(ami_data_label),
                linestyle='dashed'
            )

            plt.title(day_type.replace("_", " "))
            plt.xlim([0, 23])
            plt.ylim([0, y_max * 1.1])

            if fig_n > 4:
                plt.xlabel('Hour of Day', fontsize=24)
            if fig_n % 2 != 0:
                plt.ylabel(ylabel_text, fontsize=24)

            # collect graph data
            data_df = processed_data_for_stack_plot.copy()
            data_df['hour'] = data_df.index
            data_df['region'] = region['source_name']
            data_df['building_type'] = building_type
            data_df['day_type'] = day_type
            #data_df['lci80'] = lower_truth
            data_df['ami_total'] = truth_data
            #data_df['uci80'] = upper_truth
            data_df['graph_type'] = graph_type
            data_df['ami_n_min'] = ami_count_min
            data_df['ami_n_mean'] = ami_count_avg
            data_df['ami_n_max'] = ami_count_max
            data_df['comstock_n_min'] = comstock_count_min
            data_df['comstock_n_mean'] = comstock_count_avg
            data_df['comstock_n_max'] = comstock_count_max

            # add comstock total
            processed_total_data = pd.DataFrame(comstock_data['total'][comstock_day_type_dict[day_type]])
            processed_total_data['hour'] = processed_total_data.index.hour
            processed_total_data = processed_total_data.groupby('hour', observed=True).mean()
            data_df['comstock_total'] = processed_total_data
            data_df['error'] = data_df['ami_total'] - data_df['comstock_total']
            data_df['relative_error'] = (data_df['ami_total'] - data_df['comstock_total']) / data_df['ami_total']

            # add to total plot data
            data_df = data_df.reset_index(drop=True)
            plot_data_df = pd.concat([plot_data_df, data_df])

        ax = plt.gca()
        handles, labels = ax.get_legend_handles_labels()
        plt.figlegend(handles[::-1], labels[::-1], loc='center right', bbox_to_anchor=(1.2, 0.52), ncol=1)

        # save plot
        output_path = os.path.abspath(os.path.join(output_dir, '%s.png' % (filename) ))
        plt.savefig(output_path, bbox_inches='tight')

        # save graph data
        if save_graph_data:
            output_path = os.path.abspath(os.path.join(output_dir, '%s.csv' % (filename) ))
            plot_data_df.to_csv(output_path, index=False)

        plt.close('all')
        return plot_data_df

    """
    Load duration curve comparison
    Args:
        df: long form dataset with a comstock run and ami data
        region: region object from AMI class
        building_type (str): building type
        color_map: hash with dataset names as the keys
        output_dir (str): output directory
    """
    def plot_load_duration_curve(self, df, region, building_type, color_map, output_dir):
        comstock_data_label = list(color_map.keys())[0]
        ami_data_label = list(color_map.keys())[1]
        energy_column = 'kwh_per_sf'
        default_uncertainty = 0.1
        zoom_in_hours = -1

        total_data = df.loc[df.enduse.isin(['total'])]

        # format comstock data
        comstock_data = total_data.loc[total_data.run.isin([comstock_data_label])][['run', energy_column]]
        comstock_data = comstock_data.pivot(columns='run', values=[energy_column])
        comstock_data.columns = comstock_data.columns.droplevel(0)
        comstock_data = comstock_data.reset_index().rename_axis(None, axis=1)
        comstock_data = comstock_data.set_index('timestamp')

        # format ami data
        ami_data = total_data.loc[total_data.run.isin([ami_data_label])][['run', energy_column]]
        ami_data = ami_data.pivot(columns='run', values=[energy_column])
        ami_data.columns = ami_data.columns.droplevel(0)
        ami_data = ami_data.reset_index().rename_axis(None, axis=1)
        ami_data = ami_data.set_index('timestamp')

        # assign sample uncertainty
        try:
            sample_uncertainty = np.array(total_data.loc[total_data.run.isin([ami_data_label])][['sample_uncertainty']])
        except KeyError:
            sample_uncertainty = total_data.loc[total_data.run.isin([ami_data_label])][['run', energy_column]]
            sample_uncertainty.rename(columns={energy_column: 'sample_uncertainty'}, inplace=True)
            sample_uncertainty['sample_uncertainty'] = default_uncertainty
            sample_uncertainty = np.array(sample_uncertainty['sample_uncertainty']).reshape(-1, 1)

        # set up default values
        if zoom_in_hours == -1:
            zoom_in_hours = len(ami_data)

        # sort values
        ami_data_sorted = ami_data.sort_values(
            by=list(ami_data.columns), ascending=False).reset_index(drop=True).iloc[0:zoom_in_hours, :]
        ami_data_sorted = ami_data_sorted.reset_index(drop=True)
        comstock_data_sorted = pd.DataFrame(
            np.sort(comstock_data.values,
                    axis=0)[::-1],
            index=comstock_data.index,
            columns=comstock_data.columns
        ).iloc[0:zoom_in_hours, :]
        comstock_data_sorted = comstock_data_sorted.reset_index(drop=True)
        sample_uncertainty = sample_uncertainty[0:zoom_in_hours].max()

        # plot
        plt.figure(figsize=(12, 8))
        plt.ylabel('kwh/ft2', fontsize=16)
        plt.plot(comstock_data_sorted, color='#d73027', linewidth=2)
        y = ami_data_sorted
        plt.plot(y + y * sample_uncertainty, color='k', linestyle='dashed')
        plt.plot(y, color='k')
        plt.plot(y - y * sample_uncertainty, color='k', linestyle='dashed')
        plt.xlabel('Hours Equaled or Exceeded', fontsize=16)

        y_max = max([ami_data_sorted.values.max(), comstock_data_sorted.values.max()])
        y_min = 0
        if zoom_in_hours < 501:
            y_min = 0.9 * min([ami_data_sorted.values.min(), comstock_data_sorted.values.min()])
        plt.xlim(0, len(ami_data_sorted))
        plt.ylim([y_min, 1.1 * y_max])
        plt.yticks(fontsize=15)
        plt.xticks(fontsize=15)
        plt.legend([comstock_data_label] + [ami_data_label + ': upper estimate'] +
                    [ami_data_label] + [ami_data_label + ': lower estimate'], fontsize=15, loc=1)
        plt.title('{}, {}, Load Duration Curve: {} hours'.format(region['source_name'], building_type, len(ami_data_sorted)), fontsize=19)

        # output figure
        filename = region['source_name'] + '_' + ami_data_label.lower().replace(' ', '') + '_' + building_type + '_load_duration_curve_top_' + str(zoom_in_hours) + '_hours.png'
        output_path = os.path.abspath(os.path.join(output_dir, filename))
        plt.savefig(output_path, bbox_inches='tight')

    # plot
    order_list = [
                'interior_equipment',
                'fans',
                'interior_lighting',
                'exterior_lighting',
                'cooling',
                'heating',
                'water_systems',
                'refrigeration',
                'pumps',
                'heat_rejection',
                'heat_recovery',
                ]

    def map_to_season(month):
        if 3 <= month <= 5:
            return 'Spring'
        elif 6 <= month <= 8:
            return 'Summer'
        elif 9 <= month <= 11:
            return 'Fall'
        else:
            return 'Winter'

    def plot_measure_timeseries_peak_week_by_state(self, df, output_dir, timeseries_locations_to_plot, color_map, comstock_run_name, comstock_obj=None): #, df, region, building_type, color_map, output_dir

        # get upgrade ID
        df_data = df.copy(deep=True)
        # coerce data type of upgrade ID - arrives as float, need str of int for querying
        df_data[self.UPGRADE_ID] = pd.to_numeric(df_data[self.UPGRADE_ID], errors="coerce").astype("Int64").astype(str)
        df_upgrade = df_data.loc[(df_data[self.UPGRADE_ID]!="0"), :]
        upgrade_num = list(df_upgrade[self.UPGRADE_ID].unique())
        upgrade_name = list(df_upgrade[self.UPGRADE_NAME].unique())

        # apply queries and weighting
        for location, location_name in timeseries_locations_to_plot.items():
            dfs_base_combined, dfs_upgrade_combined = comstock_obj.get_weighted_load_profiles_from_s3(df_data, upgrade_num, location, upgrade_name)

            # merge into single dataframe
            dfs_merged = pd.concat([dfs_base_combined, dfs_upgrade_combined], ignore_index=True)

            # set index
            dfs_merged.set_index("time", inplace=True)
            dfs_merged['Month'] = dfs_merged.index.month

            def map_to_season(month):
                if 3 <= month <= 5:
                    return 'Spring'
                elif 6 <= month <= 8:
                    return 'Summer'
                elif 9 <= month <= 11:
                    return 'Fall'
                else:
                    return 'Winter'

            # Apply the mapping function to create the "Season" column
            dfs_merged['Season'] = dfs_merged['Month'].apply(map_to_season)
            dfs_merged['Week_of_Year'] = dfs_merged.index.isocalendar().week
            dfs_merged['Day_of_Year'] = dfs_merged.index.dayofyear
            dfs_merged['Day_of_Week'] = dfs_merged.index.dayofweek
            dfs_merged['Hour_of_Day'] = dfs_merged.index.hour
            dfs_merged['Year'] = dfs_merged.index.year
            # make dec 31st last week of year
            dfs_merged.loc[dfs_merged['Day_of_Year']==365, 'Week_of_Year'] = 55
            dfs_merged = dfs_merged.loc[dfs_merged['Year']==2018, :]
            max_peak = dfs_merged.loc[:, 'total_site_electricity_kwh'].max()

            # find peak week by season
            seasons = ['Spring', 'Summer', 'Fall', 'Winter']
            for season in seasons:
                peak_week = dfs_merged.loc[dfs_merged['Season']==season, ["total_site_electricity_kwh", "Week_of_Year"]]
                peak_week = peak_week.loc[peak_week["total_site_electricity_kwh"] == peak_week["total_site_electricity_kwh"].max(), "Week_of_Year"].iloc[0]


                # filter to the week
                dfs_merged_pw = dfs_merged.loc[dfs_merged["Week_of_Year"]==peak_week, :].copy()
                #dfs_merged_pw = dfs_merged_pw.loc[:, dfs_merged_pw.columns.str.contains("electricity")]
                dfs_merged_pw.reset_index(inplace=True)
                dfs_merged_pw = dfs_merged_pw.sort_values('time')

                # rename columns
                dfs_merged_pw.columns = dfs_merged_pw.columns.str.replace("electricity_", "")
                dfs_merged_pw.columns = dfs_merged_pw.columns.str.replace("_kwh", "")

                # convert hourly kWH to 15 minute MW
                dfs_merged_pw.loc[:, self.order_list] = dfs_merged_pw.loc[:, self.order_list]/1000
                dfs_merged_pw.loc[:, "total_site"] = dfs_merged_pw.loc[:, "total_site"]/1000

                # add upgrade traces
                # Create traces for area plot
                traces = []
                # add aggregate measure load
                dfs_merged_pw_up = dfs_merged_pw.loc[dfs_merged_pw['in.upgrade_name'] != "Baseline"]
                dfs_merged_pw_up.columns = dfs_merged_pw_up.columns.str.replace("total_site", "Measure Total")

                # if only 1 upgrade, plot end uses and total
                if len(upgrade_num) == 1:
                    # loop through end uses
                    for enduse in self.order_list:
                        trace = go.Scatter(
                            x=dfs_merged_pw_up['time'],
                            y=dfs_merged_pw_up[enduse],
                            fill='tonexty',
                            fillcolor=self.PLOTLY_ENDUSE_COLOR_DICT[enduse.replace('_'," ").title()],
                            mode='none',
                            line=dict(color=self.PLOTLY_ENDUSE_COLOR_DICT[enduse.replace('_'," ").title()], width=0.5),
                            name=enduse,
                            stackgroup='stack'
                        )
                        traces.append(trace)

                    # Create a trace for the upgrade load
                    upgrade_trace = go.Scatter(
                        x=dfs_merged_pw_up['time'],
                        y=dfs_merged_pw_up['Measure Total'],
                        mode='lines',
                        line=dict(color='black', width=1.8, dash='solid'),
                        name='Measure Total',
                    )
                    traces.append(upgrade_trace)
                else:
                    # if more than 1 upgrade, add only aggregate loads
                    for upgrade in upgrade_num:
                        dfs_merged_pw_up_mult = dfs_merged_pw_up.loc[dfs_merged_pw_up['in.upgrade_name'] == self.dict_upid_to_upname[int(upgrade)]]
                        upgrade_trace = go.Scatter(
                        x=dfs_merged_pw_up_mult['time'],
                        y=dfs_merged_pw_up_mult['Measure Total'],
                        mode='lines',
                        line=dict(width=1.8, dash='solid'), #color=color_map[self.dict_upid_to_upname[int(upgrade)]]
                        name=self.dict_upid_to_upname[int(upgrade)],
                        )
                        traces.append(upgrade_trace)


                # add baseline load
                dfs_merged_pw_base = dfs_merged_pw.loc[dfs_merged_pw['in.upgrade_name']=="Baseline"]
                dfs_merged_pw_base.columns = dfs_merged_pw_base.columns.str.replace("total_site", "Baseline Total")

                # Create a trace for the baseline load
                baseline_trace = go.Scatter(
                    x=dfs_merged_pw_base['time'],
                    y=dfs_merged_pw_base['Baseline Total'],
                    mode='lines',
                    #line=dict(color='black', width=1.75),
                    line=dict(color='black', width=1.8, dash='dot'),
                    name='Baseline Total'
                )
                traces.append(baseline_trace)

                # Create the layout
                layout = go.Layout(
                    #title=f"{season} Peak Week - {state_name}",
                    xaxis=dict(mirror=True, title=None, showline=True),
                    yaxis=dict(mirror=True, title='Electricity Demand (MW)', range=[0, max_peak/1000], showline=True),
                    legend=dict(font=dict(size=8), y=1.02, xanchor="left", x=0.0, orientation="h", yanchor="bottom", itemwidth=30),
                    legend_traceorder="reversed",
                    showlegend=True,
                    template='simple_white',
                    width=650,
                    height=400,
                    annotations=[
                                dict(x=-0.1,  # Centered on the x-axis
                                    y=-0.35,  # Adjust this value as needed to place the title correctly
                                    xref='paper',
                                    yref='paper',
                                    text=f"{season} Peak Week, Applicable Buildings - {location_name}",
                                    showarrow=False,
                                    font=dict(
                                        size=16
                                    ))]
                )

                # Create the figure
                fig = go.Figure(data=traces, layout=layout)

                # Save fig
                title = f"{season}_peak_week"
                fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
                fig_name_html = f'{title.replace(" ", "_").lower()}.html'
                fig_sub_dir = os.path.abspath(os.path.join(output_dir, f"timeseries/{location_name}"))
                if not os.path.exists(fig_sub_dir):
                    os.makedirs(fig_sub_dir)
                fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
                fig_path_html = os.path.abspath(os.path.join(fig_sub_dir, fig_name_html))

                self.queue_figure(fig, fig_path, scale=6)
                #fig.write_html(fig_path_html)
            # save timeseries data
            dfs_merged.to_csv(f"{fig_sub_dir}/timeseries_data_{location_name}.csv")

    def plot_measure_timeseries_season_average_by_state(self, df, output_dir, timeseries_locations_to_plot, color_map, comstock_run_name, comstock_obj=None):

        # get upgrade ID
        df_data = df.copy()
        # coerce data type of upgrade ID - arrives as float, need str of int for querying
        df_data[self.UPGRADE_ID] = pd.to_numeric(df_data[self.UPGRADE_ID], errors="coerce").astype("Int64").astype(str)
        df_upgrade = df_data.loc[(df_data[self.UPGRADE_ID]!="0") & (df_data[self.UPGRADE_ID]!=0), :]
        upgrade_num = list(df_upgrade[self.UPGRADE_ID].unique())
        upgrade_name = list(df_upgrade[self.UPGRADE_NAME].unique())

        standard_colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f', '#bcbd22', '#17becf']
        upgrade_colors = {upgrade: standard_colors[i % len(standard_colors)] for i, upgrade in enumerate(upgrade_num)}

        def map_to_season(month):
            if 3 <= month <= 5 or 9 <= month <= 11:
                return 'Shoulder'
            elif 6 <= month <= 8:
                return 'Summer'
            else:
                return 'Winter'

        def map_to_dow(dow):
            if dow < 5:
                return 'Weekday'
            else:
                return 'Weekend'

        # apply queries and weighting
        for location, location_name in timeseries_locations_to_plot.items():

            # check to see if timeseries file exists.
            # if it does, reload. Else, query data.
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, f"timeseries/{location_name}"))
            file_path = os.path.join(fig_sub_dir, f"timeseries_data_{location_name}.csv")
            dfs_merged=None
            if not os.path.exists(file_path):
                dfs_base_combined, dfs_upgrade_combined = comstock_obj.get_weighted_load_profiles_from_s3(df_data, upgrade_num, location, upgrade_name)

                # merge into single dataframe
                dfs_merged = pd.concat([dfs_base_combined, dfs_upgrade_combined], ignore_index=True)

                # set index
                dfs_merged.set_index("time", inplace=True)
                dfs_merged['Month'] = dfs_merged.index.month

                # Apply the mapping function to create the "Season" column
                dfs_merged['Season'] = dfs_merged['Month'].apply(map_to_season)
                dfs_merged['Week_of_Year'] = dfs_merged.index.isocalendar().week
                dfs_merged['Day_of_Year'] = dfs_merged.index.dayofyear
                dfs_merged['Hour_of_Day'] = dfs_merged.index.hour
                dfs_merged['Day_of_Week'] = dfs_merged.index.dayofweek
                dfs_merged['Day_Type'] = dfs_merged['Day_of_Week'].apply(map_to_dow)
                dfs_merged['Year'] = dfs_merged.index.year

                # make dec 31st last week of year
                dfs_merged.loc[dfs_merged['Day_of_Year']==365, 'Week_of_Year'] = 55
                dfs_merged = dfs_merged.loc[dfs_merged['Year']==2018, :]
            else:
                print("Using existing timeseries file. Please delete if this is not the intent.")
                dfs_merged = pd.read_csv(file_path)
                dfs_merged['Season'] = dfs_merged['Month'].apply(map_to_season)
                dfs_merged['Day_Type'] = dfs_merged['Day_of_Week'].apply(map_to_dow)

            dfs_merged_gb = dfs_merged.groupby(['in.upgrade_name', 'Season', 'Day_Type', 'Hour_of_Day'], observed=True)[dfs_merged.loc[:, dfs_merged.columns.str.contains('_kwh')].columns].mean().reset_index()
            max_peak = dfs_merged_gb.loc[:, 'total_site_electricity_kwh'].max()

            # find peak week by season
            seasons = ['Summer', 'Shoulder', 'Winter']
            day_types = ['Weekday', 'Weekend']
            fig = make_subplots(rows=3, cols=2, subplot_titles=[f"{season} - {day_type}" for season in seasons for day_type in day_types], vertical_spacing=0.10)

            season_to_subplot = {
                ('Summer', 'Weekday'): (1, 1),
                ('Summer', 'Weekend'): (1, 2),
                ('Shoulder', 'Weekday'): (2, 1),
                ('Shoulder', 'Weekend'): (2, 2),
                ('Winter', 'Weekday'): (3, 1),
                ('Winter', 'Weekend'): (3, 2),
            }

            legend_entries = set()
            for season in seasons:
                for day_type in day_types:
                    row, col = season_to_subplot[(season, day_type)]
                    # filter to the week
                    dfs_merged_pw = dfs_merged_gb.loc[(dfs_merged_gb["Season"] == season) & (dfs_merged_gb["Day_Type"] == day_type), :].copy()
                    dfs_merged_pw.reset_index(inplace=True)

                    # rename columns
                    dfs_merged_pw.columns = dfs_merged_pw.columns.str.replace("electricity_", "")
                    dfs_merged_pw.columns = dfs_merged_pw.columns.str.replace("_kwh", "")

                    # convert hourly kWH to 15 minute MW
                    dfs_merged_pw.loc[:, self.order_list] = dfs_merged_pw.loc[:, self.order_list]/1000
                    dfs_merged_pw.loc[:, "total_site"] = dfs_merged_pw.loc[:, "total_site"]/1000
                    dfs_merged_pw = dfs_merged_pw.sort_values('Hour_of_Day')
                    dfs_merged_pw_up = dfs_merged_pw.loc[dfs_merged_pw['in.upgrade_name'] != 'Baseline', :]
                    dfs_merged_pw_up.columns = dfs_merged_pw_up.columns.str.replace("total_site", "Measure Total")
                    dfs_merged_pw_up = dfs_merged_pw_up.loc[dfs_merged_pw['in.upgrade_name'] != 'Baseline', :]

                    if len(upgrade_num) == 1:
                        # Create traces for area plot
                        for enduse in self.order_list:

                            showlegend = enduse not in legend_entries
                            legend_entries.add(enduse)

                            trace = go.Scatter(
                                x=dfs_merged_pw_up['Hour_of_Day'],
                                y=dfs_merged_pw_up[enduse],
                                fill='tonexty',
                                fillcolor=self.PLOTLY_ENDUSE_COLOR_DICT[enduse.replace('_'," ").title()],
                                mode='none',
                                line=dict(color=self.PLOTLY_ENDUSE_COLOR_DICT[enduse.replace('_'," ").title()], width=0.5),
                                name=enduse,
                                stackgroup='stack',
                                showlegend=showlegend
                            )
                            fig.add_trace(trace, row=row, col=col)

                        showlegend = 'Measure Total' not in legend_entries
                        legend_entries.add('Measure Total')

                        # Create a trace for the baseline load
                        upgrade_trace = go.Scatter(
                            x=dfs_merged_pw_up['Hour_of_Day'],
                            y=dfs_merged_pw_up['Measure Total'],
                            mode='lines',
                            line=dict(color='black', width=3, dash='solid'),
                            name='Measure Total',
                            showlegend=showlegend
                        )
                        fig.add_trace(upgrade_trace, row=row, col=col)

                    else:

                        # if more than 1 upgrade, add only aggregate loads
                        for upgrade in upgrade_num:
                            showlegend = upgrade not in legend_entries
                            legend_entries.add(upgrade)

                            dfs_merged_pw_up_mult = dfs_merged_pw_up.loc[dfs_merged_pw_up['in.upgrade_name'] == self.dict_upid_to_upname[int(upgrade)], :]
                            upgrade_trace = go.Scatter(
                            x=dfs_merged_pw_up_mult['Hour_of_Day'],
                            y=dfs_merged_pw_up_mult['Measure Total'],
                            mode='lines',
                            line=dict(color=upgrade_colors[upgrade], width=1.8, dash='solid'), #color=color_map[self.dict_upid_to_upname[int(upgrade)]]
                            name=self.dict_upid_to_upname[int(upgrade)],
                            legendgroup=self.dict_upid_to_upname[int(upgrade)],
                            showlegend=showlegend
                            )
                            fig.add_trace(upgrade_trace, row=row, col=col)


                    # add baseline load
                    dfs_merged_pw_base = dfs_merged_pw.loc[dfs_merged_pw['in.upgrade_name'] == "Baseline"]
                    dfs_merged_pw_base.columns = dfs_merged_pw_base.columns.str.replace("total_site", "Baseline Total")

                    showlegend = 'Baseline Total' not in legend_entries
                    legend_entries.add('Baseline Total')

                    # Create a trace for the baseline load
                    baseline_trace = go.Scatter(
                        x=dfs_merged_pw_base['Hour_of_Day'],
                        y=dfs_merged_pw_base['Baseline Total'],
                        mode='lines',
                        line=dict(color='black', width=3, dash='dash'),
                        name='Baseline Total',
                        legendgroup='Baseline Total',
                        showlegend=showlegend
                    )
                    fig.add_trace(baseline_trace, row=row, col=col)

                    fig.update_xaxes(title_text='Hour of Day', showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True, tickvals=[0, 6, 12, 18, 23], ticktext=["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"])
                    fig.update_yaxes(title_text='Electricity Demand (MW)', showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True, range=[0, max_peak/1000])

            # Update layout
            fig.update_layout(
                title=f"Seasonal Average, Applicable Buildings - {location_name}</b>",
                title_x=0.04,  # Align title to the left
                title_y=0.97,  # Move title to the bottom
                title_xanchor='left',
                title_yanchor='bottom',
                legend_traceorder="reversed",
                showlegend=True,
                legend=dict(
                font=dict(
                    size=16  # Increase the font size of the legend
                    )
                ),
                template='simple_white',
                width=1200,
                height=1200
            )

            # Save fig
            title = "seasonal_average_subplot"
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name_html = f'{title.replace(" ", "_").lower()}.html'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, f"timeseries/{location_name}"))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            fig_path_html = os.path.abspath(os.path.join(fig_sub_dir, fig_name_html))

            self.queue_figure(fig, fig_path, scale=6)
            #fig.write_html(fig_path_html)

    def plot_measure_timeseries_annual_average_by_state_and_enduse(self, df, output_dir, timeseries_locations_to_plot, color_map, comstock_run_name, comstock_obj=None):

        # get upgrade ID
        df_data = df.copy()
        # coerce data type of upgrade ID - arrives as float, need str of int for querying
        df_data[self.UPGRADE_ID] = pd.to_numeric(df_data[self.UPGRADE_ID], errors="coerce").astype("Int64").astype(str)
        df_upgrade = df_data.loc[(df_data[self.UPGRADE_ID]!="0"), :]
        upgrade_num = list(df_upgrade[self.UPGRADE_ID].unique())
        upgrade_name = list(df_upgrade[self.UPGRADE_NAME].unique())

        standard_colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f', '#bcbd22', '#17becf']
        upgrade_colors = {upgrade: standard_colors[i % len(standard_colors)] for i, upgrade in enumerate(upgrade_num)}

        def map_to_season(month):
            if 3 <= month <= 5 or 9 <= month <= 11:
                return 'Shoulder'
            elif 6 <= month <= 8:
                return 'Summer'
            else:
                return 'Winter'

        def map_to_dow(dow):
            if dow < 5:
                return 'Weekday'
            else:
                        return 'Weekend'

        # apply queries and weighting
        for state, state_name in timeseries_locations_to_plot.items():

            # check to see if timeseries data already exists
            # check to see if timeseries file exists.
            # if it does, reload. Else, query data.
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, f"timeseries/{state_name}"))
            file_path = os.path.join(fig_sub_dir, f"timeseries_data_{state_name}.csv")
            dfs_merged=None

            if not os.path.exists(file_path):

                ######### This is where we get the weighted data
                dfs_base_combined, dfs_upgrade_combined = comstock_obj.get_weighted_load_profiles_from_s3(df_data, upgrade_num, state, upgrade_name)
                #########

                # merge into single dataframe
                dfs_merged = pd.concat([dfs_base_combined, dfs_upgrade_combined], ignore_index=True)

                # set index
                dfs_merged.set_index("time", inplace=True)
                dfs_merged['Month'] = dfs_merged.index.month

                # Apply the mapping function to create the "Season" column
                dfs_merged['Season'] = dfs_merged['Month'].apply(map_to_season)
                dfs_merged['Week_of_Year'] = dfs_merged.index.isocalendar().week
                dfs_merged['Day_of_Year'] = dfs_merged.index.dayofyear
                dfs_merged['Hour_of_Day'] = dfs_merged.index.hour
                dfs_merged['Day_of_Week'] = dfs_merged.index.dayofweek
                dfs_merged['Day_Type'] = dfs_merged['Day_of_Week'].apply(map_to_dow)
                dfs_merged['Year'] = dfs_merged.index.year

                # make Dec 31st last week of year
                dfs_merged.loc[dfs_merged['Day_of_Year'] == 365, 'Week_of_Year'] = 55
                dfs_merged = dfs_merged.loc[dfs_merged['Year'] == 2018, :]
            else:
                print("Using existing timeseries file. Please delete if this is not the intent.")
                dfs_merged = pd.read_csv(file_path)
                dfs_merged['Season'] = dfs_merged['Month'].apply(map_to_season)

            dfs_merged_gb = dfs_merged.groupby(['in.upgrade_name', 'Season', 'Hour_of_Day'], observed=True)[dfs_merged.loc[:, dfs_merged.columns.str.contains('_kwh')].columns].mean().reset_index()

            # rename columns, convert units
            dfs_merged_gb.columns = dfs_merged_gb.columns.str.replace("electricity_", "")
            dfs_merged_gb.columns = dfs_merged_gb.columns.str.replace("_kwh", "")

            # find peak week by season
            seasons = ['Summer', 'Shoulder', 'Winter']

            enduses_to_subplot = {
                'heat_recovery': 1,
                'heat_rejection': 2,
                'pumps': 3,
                'refrigeration': 4,
                'water_systems': 5,
                'heating': 6,
                'cooling': 7,
                'exterior_lighting': 8,
                'interior_lighting': 9,
                'fans': 10,
                'interior_equipment': 11
            }

            # Generate subplot titles dynamically
            subplot_titles = []
            for enduse, row in enduses_to_subplot.items():
                for season in seasons:
                    subplot_titles.append(f"{season}: {enduse}")

            fig = make_subplots(
                rows=11, cols=3,
                subplot_titles=subplot_titles,
                shared_xaxes=True, shared_yaxes=True, vertical_spacing=0.02)

            for enduse in self.order_list:
                for i, season in enumerate(seasons):
                    row = enduses_to_subplot[enduse]
                    col = i + 1

                    # filter to the week
                    dfs_merged_gb_season = dfs_merged_gb.loc[(dfs_merged_gb["Season"] == season), :].copy()
                    dfs_merged_gb_season.reset_index(inplace=True)

                    # sort for hour of day
                    dfs_merged_gb_season = dfs_merged_gb_season.sort_values('Hour_of_Day')

                    # add legend to first entry
                    showlegend = False
                    if row == 1 and col == 1:
                        showlegend = True

                    # add upgrade
                    dfs_merged_gb_season_up = dfs_merged_gb_season.loc[dfs_merged_gb_season['in.upgrade_name'] != 'Baseline', :]
                    # if only 1 upgrade, plot end uses and total
                    if len(upgrade_num) == 1:
                        trace = go.Scatter(
                            x=dfs_merged_gb_season_up['Hour_of_Day'],
                            y=dfs_merged_gb_season_up[enduse]/1000,
                            mode='lines',
                            line=dict(color=color_map[upgrade_name[0]], width=2),
                            name=f"{upgrade_name[0]}",
                            showlegend=showlegend
                        )
                        fig.add_trace(trace, row=row, col=col)
                    else:
                        # if more than 1 upgrade, add only aggregate loads
                        for upgrade in upgrade_num:
                            dfs_merged_pw_up_mult = dfs_merged_gb_season_up.loc[dfs_merged_gb_season_up['in.upgrade_name'] == self.dict_upid_to_upname[int(upgrade)]]

                            upgrade_trace = go.Scatter(
                            x=dfs_merged_pw_up_mult['Hour_of_Day'],
                            y=dfs_merged_pw_up_mult[enduse]/1000,
                            mode='lines',
                            line=dict(color=upgrade_colors[upgrade], width=1.8, dash='solid'), #color=color_map[self.dict_upid_to_upname[int(upgrade)]]
                            name=self.dict_upid_to_upname[int(upgrade)],
                            legendgroup=self.dict_upid_to_upname[int(upgrade)],
                            showlegend=showlegend
                            )
                            fig.add_trace(upgrade_trace, row=row, col=col)

                    # add baseline load
                    dfs_merged_gb_season_base = dfs_merged_gb_season.loc[dfs_merged_gb_season['in.upgrade_name'] == "Baseline"]
                    baseline_trace = go.Scatter(
                        x=dfs_merged_gb_season_base['Hour_of_Day'],
                        y=dfs_merged_gb_season_base[enduse]/1000,
                        mode='lines',
                        line=dict(color="Black", width=2, dash='dash'),
                        name='Baseline',
                        showlegend=showlegend
                    )
                    fig.add_trace(baseline_trace, row=row, col=col)

                    # update axes for subplot
                    if row == 6 and col == 2:
                        fig.update_xaxes(title_text=None, showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True, tickvals=[0, 6, 12, 18, 23], ticktext=["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"])
                    else:
                        fig.update_xaxes(showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True, tickvals=[0, 6, 12, 18, 23], ticktext=["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"])

                    if col == 1 and row == 6:
                        fig.update_yaxes(title_text='Electricity Demand (MW)', showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True)  # , range=[0, max_peak/1000]
                    else:
                        fig.update_yaxes(showline=True, linewidth=2, linecolor='black', row=row, col=col, mirror=True)

            # Update layout
            fig.update_layout(
                title=f"Seasonal Average, Applicable Buildings - {state_name}</b>",
                title_x=0.04,  # Align title to the left
                title_y=0.97,  # Move title to the bottom
                title_xanchor='left',
                title_yanchor='bottom',
                legend_traceorder="reversed",
                showlegend=True,
                legend=dict(
                    font=dict(
                        size=16  # Increase the font size of the legend
                    )
                ),
                template='simple_white',
                # width=300,
                height=1400
            )

            fig.update_annotations(font_size=10)

            # Save fig
            title = "seasonal_average_enduse"
            fig_name = f'{title.replace(" ", "_").lower()}.{self.image_type}'
            fig_name_html = f'{title.replace(" ", "_").lower()}.html'
            fig_sub_dir = os.path.abspath(os.path.join(output_dir, f"timeseries/{state_name}"))
            if not os.path.exists(fig_sub_dir):
                os.makedirs(fig_sub_dir)
            fig_path = os.path.abspath(os.path.join(fig_sub_dir, fig_name))
            fig_path_html = os.path.abspath(os.path.join(fig_sub_dir, fig_name_html))

            self.queue_figure(fig, fig_path, scale=6)
            #fig.write_html(fig_path_html)

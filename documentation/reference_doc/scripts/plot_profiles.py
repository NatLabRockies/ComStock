"""Plot occupancy profiles exported from the gem's own expansion (export_profiles.rb)."""
import json
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

import os
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'figures') + os.sep
P = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'profiles.json'), encoding='utf-8'))

PART1 = ['office', 'conference/meeting/multipurpose', 'lobby', 'retail', 'retail - supermarket', 'classroom/lecture/training - primary school',
         'classroom/lecture/training - secondary school', 'library - primary school', 'dining', 'dining - cafeteria/fast food', 'food preparation', 'food preparation - primary school']
PART2 = ['guest room', 'laundry/washing', 'exam/treatment', 'nurses station', 'patient room', 'operating room',
         'emergency room', 'imaging', 'physical therapy', 'lounge/breakroom', 'storage', 'exercise area']


def day_profile(st, day):
    days = P[st]['days']
    if day == 'Default':
        return days.get('Default')
    for key in (day, 'Wknd|Hol'):
        if key in days:
            return days[key]
    return days.get('Default')


def panel_grid(types, days, fname, title):
    rows = (len(types) + 3) // 4
    fig, axes = plt.subplots(rows, 4, figsize=(13, 2.75 * rows), sharex=True, sharey=True)
    for ax, st in zip(axes.flat, types):
        for day, color, label in days:
            prof = day_profile(st, day)
            if prof is None:
                ax.text(0.5, 0.5, 'no occupancy', transform=ax.transAxes, ha='center', va='center', color='gray')
                continue
            t = [p[0] for p in prof['pairs']]
            v = [p[1] for p in prof['pairs']]
            ax.step(t, v, where='post', color=color, lw=1.6, label=label)
            if day == 'Default':
                ax.axvline(prof['st'], color='gray', ls='--', lw=0.8)
                ax.axvline(prof['et'], color='gray', ls='--', lw=0.8)
        ax.set_title(st, fontsize=9.5)
        ax.set_xlim(0, 24); ax.set_ylim(0, 1.02); ax.set_xticks([0, 6, 12, 18, 24]); ax.grid(alpha=0.3)
    for ax in axes[-1]:
        ax.set_xlabel('hour of day')
    for ax in axes[:, 0]:
        ax.set_ylabel('occupancy fraction')
    handles, labels = axes.flat[0].get_legend_handles_labels()
    if len(days) > 1:
        fig.legend(handles, labels, loc='lower center', ncol=len(days), frameon=False, bbox_to_anchor=(0.5, -0.01))
    fig.suptitle(title, fontsize=12)
    fig.tight_layout(rect=(0, 0.03 if len(days) > 1 else 0, 1, 0.97))
    fig.savefig(OUT + fname, dpi=160)
    plt.close(fig)
    print('wrote', fname)


WEEKDAY = [('Default', '#0075BB', 'weekday')]
WEEKEND = [('Sat', '#DB9728', 'Saturday'), ('Sun|Hol', '#003A69', 'Sunday and holidays')]
panel_grid(PART1, WEEKDAY, 'parametric_occupancy_1.png', 'Weekday occupancy profiles at standalone hours (dashed lines: standalone start and end times)')
panel_grid(PART2, WEEKDAY, 'parametric_occupancy_2.png', 'Weekday occupancy profiles at standalone hours (dashed lines: standalone start and end times)')
panel_grid(PART1 + PART2, WEEKEND, 'parametric_occupancy_weekend.png', 'Weekend occupancy profiles at standalone hours')

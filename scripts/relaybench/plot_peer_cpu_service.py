"""Render paired VMM CPU service and throughput ratios from the archived holdout replay."""
import argparse
import json
import subprocess
from pathlib import Path

from plot_contrasts import GRID, MUTED, TEAL, label, line, paper, point, renderSVG


def draw(receipt):
    pairs = receipt["scored_first_attempts"]
    summary = receipt["primary_common_clean"]
    low, high = receipt["observed_paired_bootstrap_ci95"]
    chart = paper("When did Micropod deliver more TCP throughput?",
                  "Gamma archived holdout   /   4 vCPUs per VM   /   16 matched first attempts   /   21 November 2026")
    x0, x1, top, bottom = 80, 603, 112, 336

    def x_pos(ratio):
        return x0 + (ratio - 0.3) * (x1 - x0) / 0.9

    def y_pos(ratio):
        return bottom - (ratio - 0.4) * (bottom - top) / 1.75

    for tick in (0.4, 0.6, 0.8, 1.0, 1.2):
        x = x_pos(tick)
        line(chart, x, top, x, bottom)
        label(chart, x, bottom + 18, f"{tick:.1f}", 11, color=MUTED, anchor="middle")
    for tick in (0.5, 1.0, 1.5, 2.0):
        y = y_pos(tick)
        line(chart, x0, y, x1, y, MUTED if tick == 1 else GRID, 1.5 if tick == 1 else 1)
        label(chart, x0 - 10, y + 4, f"{tick:.1f}", 12, color=MUTED, anchor="end")
    label(chart, x0, 98, "TCP throughput ratio", 12, True)
    label(chart, (x0 + x1) / 2, 378, "VMM CPU seconds per wall second, Micropod / OrbStack", 13, True, anchor="middle")
    for p in pairs:
        point(chart, x_pos(p["relative_vmm_cores"]), y_pos(p["rate_ratio"]), 5,
              TEAL if p["common_clean"] else "#a04e24", hollow=not p["common_clean"])
    label(chart, 638, 132, "Reading the ratios", 15, True)
    label(chart, 638, 159, "Above 1.0 on the vertical axis,", 12)
    label(chart, 638, 179, "Micropod delivered more MiB/s.", 12)
    point(chart, 644, 213, 5, TEAL)
    label(chart, 658, 217, f"{summary['pairs']} jointly clean pairs", 12)
    point(chart, 644, 239, 5, "#a04e24", hollow=True)
    label(chart, 658, 243, "One peer fresh-request failure", 12)
    label(chart, 638, 285, "Median paired throughput", 13, True)
    label(chart, 638, 314, f"{summary['observed_median_ratio']:.3f}", 24, True, color=TEAL)
    label(chart, 638, 337, f"95% interval {low:.3f} to {high:.3f}", 12)
    line(chart, 32, 394, 868, 394)
    label(chart, 32, 417, "Process CPU covers setup, scoring and drain. TCP throughput uses the six-second scoring window.", 12, color=MUTED)
    label(chart, 32, 438, "CPU consumed depends on both runnable demand and access to host cores. These observations cannot separate them.", 12, color=MUTED)
    return chart


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    chart = draw(json.loads(args.receipt.read_text()))
    subprocess.run(["rsvg-convert", "--zoom=1.5", "--output", args.receipt.with_suffix(".png")],
                   input=renderSVG.drawToString(chart).encode(), check=True)

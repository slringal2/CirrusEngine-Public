"""Measure the visible, sunlit upper envelope of a side-view cumulus from an RGB crop.

Requires numpy and Pillow. Coordinates refer to the original image, x1,y1 exclusive.
Output is diagnostic of this photograph/view only. The colour score is not transmittance.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def gaussian_line(values, sigma):
    radius = int(np.ceil(3 * sigma))
    offsets = np.arange(-radius, radius + 1)
    kernel = np.exp(-0.5 * (offsets / sigma) ** 2)
    return np.convolve(np.pad(values, radius, mode="edge"), kernel / kernel.sum(), mode="valid")


def envelope(score, threshold):
    # Reject isolated grain and pinholes by requiring a run of three above-threshold samples.
    above = score >= threshold
    hit = above[:-2] & above[1:-1] & above[2:]
    rows = np.argmax(hit, axis=0)
    valid = np.any(hit, axis=0) & (rows > 0)
    x = np.arange(score.shape[1])
    if valid.sum() < 0.90 * len(x):
        raise ValueError("Less than 90% of the crop has an interior upper edge. Inspect the crop.")
    y = rows.astype(float)
    xx = x[valid]
    yy = rows[valid]
    lo, hi = score[yy - 1, xx], score[yy, xx]
    y[valid] = yy - 1 + np.clip((threshold - lo) / np.maximum(hi - lo, 1.e-6), 0, 1)
    return np.interp(x, xx, y[valid]), valid


def bilinear(img, x, y):
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    dx, dy = x - x0, y - y0
    return ((1 - dy) * ((1 - dx) * img[y0, x0] + dx * img[y0, x0 + 1])
            + dy * ((1 - dx) * img[y0 + 1, x0] + dx * img[y0 + 1, x0 + 1]))


def edge_widths(score, rows, valid):
    slope = np.gradient(gaussian_line(rows, 1.5))
    position = np.arange(-10, 10.01, 0.25)
    h, w = score.shape
    widths = []
    for x in np.flatnonzero(valid):
        n = np.hypot(1, slope[x])
        xx = x - position * slope[x] / n
        yy = rows[x] + position / n
        if xx.min() < 0 or xx.max() >= w - 1 or yy.min() < 0 or yy.max() >= h - 1:
            continue
        profile = bilinear(score, xx, yy)
        air = np.median(profile[position <= -7])
        cloud = np.median(profile[position >= 7])
        if cloud - air < 0.28:
            continue
        rel = (profile - air) / (cloud - air)
        crosses = []
        for t in [0.25, 0.50, 0.75]:
            idx = np.flatnonzero((rel[:-1] < t) & (rel[1:] >= t))
            if len(idx) != 1:
                break
            k = idx[0]
            crosses.append(position[k] + 0.25 * (t - rel[k]) / (rel[k + 1] - rel[k]))
        if len(crosses) == 3 and abs(crosses[1]) <= 4:
            widths.append(crosses[2] - crosses[0])
    return np.array(widths)


def measure(path, roi, width=256, levels=(0.35, 0.50, 0.65)):
    with Image.open(path) as im:
        if not (0 <= roi[0] < roi[2] <= im.width and 0 <= roi[1] < roi[3] <= im.height):
            raise ValueError("ROI outside image")
        crop = im.convert("RGB").crop(roi)
    height = round(crop.height * width / crop.width)
    tile = crop.resize((width, height), Image.Resampling.LANCZOS)
    rgb = np.asarray(tile, dtype=float)
    red, blue = rgb[..., 0], rgb[..., 2]
    rb = (red - blue) / (red + blue + 1.e-6)
    # Per-image normalisation removes global white-balance offsets, not local lighting or haze.
    lo, hi = np.percentile(rb, [8, 92])
    if hi - lo < 0.06:
        raise ValueError("Insufficient separation between blue sky and sunlit cloud")
    score = (rb - lo) / (hi - lo)
    results = {}
    outlines = {}
    for t in levels:
        rows, valid = envelope(score, t)
        outlines[t] = rows
        results[t] = valid
    # Exclude columns where threshold choice could switch to another lobe or underlying shadow.
    common = np.logical_and.reduce(list(results.values()))
    common &= np.ptp(np.stack(list(outlines.values())), axis=0) <= 8
    results = {}
    if common.sum() < 0.5 * width:
        raise ValueError("Too few threshold-stable columns. Inspect overlay before comparing.")
    for t in levels:
        rows = outlines[t]
        normal_widths = edge_widths(score, rows, common)
        fine = gaussian_line(rows, 1.5)
        broad = gaussian_line(rows, 8)
        # Drop the ends, where filtering uses a padded boundary, and avoid interpolated columns.
        central = common.copy()
        central[:24] = central[-24:] = False
        residual = fine - broad
        results[str(t)] = {
            "threshold_stable_columns": int(common.sum()),
            "interior_columns_for_shape": int(central.sum()),
            "upper_outline_median_abs_residual": round(float(np.median(np.abs(residual[central]))), 3),
            "normal_profiles_used": len(normal_widths),
            "interquantile_normal_width_p25_p50_p75": (
                [round(float(n), 3) for n in np.percentile(normal_widths, [25, 50, 75])]
                if len(normal_widths) else None),
            "upper_outline_residual_rms": round(float(np.sqrt(np.mean(residual[central] ** 2))), 3)
        }
    info = {"roi": roi, "resampled_width": width, "resampled_height": height,
            "colour_ratio_p08_p92": [float(lo),float(hi)], "thresholds": results}
    return info, tile, outlines


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--roi", required=True, type=int, nargs=4)
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--overlay", type=Path)
    parser.add_argument("--json", type=Path)
    opts = parser.parse_args()
    info, tile, outlines = measure(opts.image, opts.roi, opts.width)
    if opts.overlay:
        draw = ImageDraw.Draw(tile)
        for (level, rows), colour in zip(outlines.items(), ["#17e7ff", "#ffcc36", "#e664d4"]):
            draw.line([(x, round(y)) for x, y in enumerate(rows)], fill=colour)
        tile.save(opts.overlay)
    report = json.dumps(info, ensure_ascii=False, indent=2)
    if opts.json:
        opts.json.write_text(report+"\n",encoding="utf-8")
    print(report)

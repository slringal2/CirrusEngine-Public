"""Measure the direction of image contrast inside a sunlit cumulus crown.

Negative values indicate that changes in brightness with height dominate.
Run on RGB captures with a cloud/sky crop specified in native pixel coordinates.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


def gaussian(image, sigma):
    radius = int(np.ceil(3 * sigma))
    offsets = np.arange(-radius, radius + 1)
    kernel = np.exp(-0.5 * (offsets / sigma) ** 2)
    kernel /= kernel.sum()

    def convolve_line(line):
        padded = np.pad(line, radius, mode="reflect")
        return np.convolve(padded, kernel, mode="valid")

    horizontal = np.apply_along_axis(convolve_line, 1, image)
    return np.apply_along_axis(convolve_line, 0, horizontal)


def directional_energy(path, roi, width=256):
    with Image.open(path) as original:
        if not (0 <= roi[0] < roi[2] <= original.width and 0 <= roi[1] < roi[3] <= original.height):
            raise ValueError("ROI outside image")
        crop = original.convert("RGB").crop(roi)
    size = (width, round(width * crop.height / crop.width))
    if min(size) < 16:
        raise ValueError("Crop too small for directional contrast")
    tile = crop.resize(size, Image.Resampling.LANCZOS)
    red, green, blue = np.asarray(tile, dtype=float).transpose(2, 0, 1)
    ratio = (red - blue) / (red + blue + 1.e-6)
    low, high = np.percentile(ratio, [8, 92])
    if high - low < 0.06:
        raise ValueError("Insufficient separation between blue sky and sunlit cloud")
    mask = (ratio - low) / (high - low) > 0.5
    interior = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(9))
    mask = np.asarray(interior) > 0
    mask[:6] = mask[-6:] = False
    mask[:, :6] = mask[:, -6:] = False
    if not mask.any():
        raise ValueError("No interior cloud samples after mask erosion")

    luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    report = {}
    for sigma in (1, 2, 4):
        contrast = gaussian(luminance, sigma) - gaussian(luminance, 4 * sigma)
        dy, dx = np.gradient(contrast)
        horizontal = dx[mask] ** 2
        vertical = dy[mask] ** 2
        strength = horizontal + vertical
        use = strength >= np.median(strength)
        ex, ey = horizontal[use].sum(), vertical[use].sum()
        report[sigma] = round(float((ex - ey) / (ex + ey)), 3) if ex + ey > 0 else None
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--roi", required=True, type=int, nargs=4)
    parser.add_argument("--width", type=int, default=256)
    args = parser.parse_args()
    print(json.dumps(directional_energy(args.image, args.roi, args.width), indent=2))

"""Compare native CirrusEngine landscape captures and make the illustrations in the guide."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# Each rectangle uses native pixels and excludes its right and bottom edges.
VIEWS = {
    "seedhead": ([6, -66], [18, -17], (220, 585, 1450, 1020)),
    "meadow": ([-6.1, -37], [18, -12], (15, 600, 685, 1035)),
    "river": ([53, 25], [-25, -14], (90, 530, 950, 850)),
    "ridge": ([240, 3320], [6, 20], (480, 380, 1530, 880)),
    "summit": ([1261, 6617], [-150, -3], (180, 250, 1700, 975)),
    "valley": ([-6.1, -37], [16, 3], (0, 450, 1920, 1080)),
}
FRAME_FIELDS = (
    "adapter", "width", "height", "frames", "quality", "weather", "solar_hour",
    "sun_elevation", "sun_azimuth", "camera_position_m", "simulation_seconds", "wind_offset_m",
)
PLATE = (
    ("seedhead", "草原の穂", (280, 750, 1480, 1040)),
    ("river", "川岸の水面", (20, 410, 1220, 700)),
    ("summit", "稜線の岩と残雪", (500, 325, 1700, 615)),
)


def read_rgb(directory, name):
    with Image.open(directory / f"{name}.png") as image:
        return image.convert("RGB")


def read_diagnostics(directory, name):
    log = (directory / f"{name}.log").read_text(encoding="utf-8-sig")
    metadata = json.loads((directory / f"{name}.json").read_text(encoding="utf-8-sig"))
    if "errors=0, warnings=0" not in log or metadata["nonfinite_samples"] != 0:
        raise ValueError(f"{directory.name}/{name} has a rendering diagnostic")
    return metadata


def check_same_frame(before, after):
    for field in (*FRAME_FIELDS, "weather_state"):
        if before[field] != after[field]:
            raise ValueError(f"Capture pair differs in {field}")
    for field in ("ground_m", "grass_lods"):
        if before["world"][field] != after["world"][field]:
            raise ValueError(f"Capture pair differs in world.{field}")


def rgb_difference(before, after):
    # Promote eight-bit samples before subtracting so darker values cannot wrap around.
    return np.abs(np.asarray(before, dtype=np.int16) - np.asarray(after, dtype=np.int16))


def make_plate(directories, destination):
    canvas = Image.new("RGB", (1260, 693), (20, 32, 27))
    draw = ImageDraw.Draw(canvas)
    heading = ImageFont.truetype("C:/Windows/Fonts/meiryo.ttc", 22)
    caption = ImageFont.truetype("C:/Windows/Fonts/meiryo.ttc", 17)
    for column, (version, directory) in enumerate(directories.items()):
        x = 16 + column * 623
        draw.text((x + 7, 10), "変更前" if version == "before" else "変更後",
                  font=heading, fill=(241, 244, 237))
        for row, (name, label, box) in enumerate(PLATE):
            y = 48 + row * 214
            crop = read_rgb(directory, name).crop(box)
            crop = crop.resize((605, 147), Image.Resampling.LANCZOS)
            canvas.paste(crop, (x, y + 29))
            draw.text((x + 7, y - 1), label, font=caption, fill=(197, 219, 190))
    canvas.save(destination, quality=95, subsampling=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, help="Folder containing the captures before and after")
    parser.add_argument("output", type=Path, help="Folder for figures and measurements.json")
    parser.add_argument("--after-dir", default="after", help="Subfolder containing the final captures")
    args = parser.parse_args()
    directories = {"before": args.captures / "before", "after": args.captures / args.after_dir}
    figures = args.output / "figures"
    figures.mkdir(parents=True, exist_ok=True)

    records = {}
    for name, (spawn, look, box) in VIEWS.items():
        metadata = {key: read_diagnostics(path, name) for key, path in directories.items()}
        check_same_frame(metadata["before"], metadata["after"])
        images = {key: read_rgb(path, name) for key, path in directories.items()}
        for key, image in images.items():
            if image.size != (1920, 1080):
                raise ValueError(f"{key}/{name} must be a 1920x1080 native capture")
            image.save(figures / f"{name}-{key}.jpg", quality=94, subsampling=0, optimize=True)

        difference = rgb_difference(images["before"], images["after"])
        left, top, right, bottom = box
        region = difference[top:bottom, left:right]
        records[name] = {
            "spawn_xz_m": spawn, "look_deg": look,
            **{field: metadata["after"][field] for field in FRAME_FIELDS},
            "native_png_sha256": {
                key: hashlib.sha256((path / f"{name}.png").read_bytes()).hexdigest()
                for key, path in directories.items()
            },
            "roi_exclusive_xyxy": box,
            "roi_mean_absolute_rgb_255": round(float(region.mean()), 4),
            "whole_screen_mean_absolute_rgb_255": round(float(difference.mean()), 4),
            "nonfinite_samples_before_after": [0, 0], "d3d11_errors_warnings_each": [0, 0],
            "grass_lods_before_after": [data["world"]["grass_lods"] for data in metadata.values()],
        }

    # Grass can mask a water pixel. Count changed water color only where both masks agree.
    masks = {}
    for key, path in directories.items():
        mask_info = read_diagnostics(path, "watermask")
        check_same_frame(read_diagnostics(path, "river"), mask_info)
        masks[key] = np.asarray(read_rgb(path, "watermask"))[:, :, 0] > 127
    overlap = masks["before"] & masks["after"]
    if not overlap.any():
        raise ValueError("The camera sees no common river surface")
    river = rgb_difference(read_rgb(directories["before"], "river"),
                          read_rgb(directories["after"], "river"))
    water = {
        "debug_view": 31, "before_pixels": int(masks["before"].sum()),
        "after_pixels": int(masks["after"].sum()), "overlap_pixels": int(overlap.sum()),
        "image_pixels": int(overlap.size), "mean_abs_rgb_255_in_overlap": round(float(river[overlap].mean()), 4),
    }
    result = {"paired_captures": records, "river_mask": water}
    (args.output / "measurements.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    make_plate(directories, figures / "comparison.jpg")
    print(f"{len(records)} matched cameras; {water['overlap_pixels']} common water pixels")


if __name__ == "__main__":
    main()

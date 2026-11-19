#!/usr/bin/env python3
"""Check a rendered sequence for flashes (SPEC 2.2, DECISIONS D19).

The verdict counts flashes the way the common photosensitivity guideline does: a flash is a pair
of opposing changes in relative luminance of 10 % of SDR white or more, the darker side below
0.8, and no pixel may see more than three in any one second. Every pixel is judged on its own,
with no allowance for small areas, so it errs towards failing. The luminance changing above 3 Hz
(the earlier 1 % rule) is still printed, for reference only.
"""

import argparse
import glob
import math
from pathlib import Path
import re
import tempfile

import numpy as np
from PIL import Image


LIMIT = 0.01             # the earlier rule, reported only
FLASH_CHANGE = 0.10      # a change counts at 10 % of SDR white …
FLASH_DARK = 0.80        # … when its darker side is below 0.8
FLASHES_PER_SECOND = 3   # more than this in any second fails
# The FFT keeps everything from two bins below 3 Hz up, so a change just above 3 Hz is never
# cut away with the slower motion (it errs towards failing), and it needs this many seconds.
MINIMUM_SECONDS = 4
# nagi-render writes Display P3 PNGs: luminance weights for P3 primaries (D65).
WEIGHTS = np.array([0.2290, 0.6917, 0.0793], dtype=np.float32)


def luminance(path, step, size):
    with Image.open(path) as image:
        if image.size != size:
            raise ValueError(f"{path} has size {image.size}, expected {size}")
        decoder, box, offset, raw = image.tile[0]
        if image.mode not in ("RGB", "RGBA"):
            # nagi-render --debug-alpha writes grey, each frame stretched to its own peak.
            raise ValueError(f"{path} is not a colour render; measure nagi-render output, not --debug-alpha")
        else:
            rgba = np.asarray(image.convert("RGBA"))[::step, ::step].astype(np.float32)
            if decoder == "zip" and raw in ("RGB;16B", "RGBA;16B"):
                # Pillow keeps the high byte. Reverse the unpacker's endianness to read the low byte.
                with Image.open(path) as low:
                    low.tile[0] = (decoder, box, offset, raw[:-1] + "L")
                    rgba = (rgba * 256 + np.asarray(low.convert("RGBA"))[::step, ::step]) / 65535
            else:
                rgba /= 255
            if np.any(rgba[..., 3] < 1):
                raise ValueError(f"{path} is transparent: render it with nagi-render --background")
            rgb = rgba[..., :3]
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    return linear @ WEIGHTS if linear.ndim == 3 else linear


def most_changes_per_second(frames, fps, band=32):
    """Per pixel, the most flash changes (half-flashes) within any one second.

    A change is registered when the luminance has moved FLASH_CHANGE or more away from the last
    extreme, against the direction of the previous change, with the darker side below FLASH_DARK.
    Works through bands of rows, so memory stays small however large the capture.
    """
    count, height, width = frames.shape
    window = min(math.ceil(fps), count)  # every pair of frames less than a second apart shares one
    most = np.zeros((height, width), dtype=np.float32)
    for top in range(0, height, band):
        rows = slice(top, min(top + band, height))
        high = np.array(frames[0, rows])
        low = high.copy()
        direction = np.zeros(high.shape, dtype=np.int8)   # +1 after a rise, −1 after a fall
        # The last second's change flags, as a ring, and their running count.
        recent = np.zeros((window,) + high.shape, dtype=bool)
        running = np.zeros(high.shape, dtype=np.int16)
        best = np.zeros(high.shape, dtype=np.int16)
        for t in range(count):
            v = np.asarray(frames[t, rows])
            # After a rise, follow the new high; after a fall, the new low; before either, both.
            high = np.where(direction >= 0, np.maximum(high, v), high)
            low = np.where(direction <= 0, np.minimum(low, v), low)
            fall = (direction != -1) & (high - v >= FLASH_CHANGE) & (v < FLASH_DARK)
            rise = (direction != 1) & ~fall & (v - low >= FLASH_CHANGE) & (low < FLASH_DARK)
            direction = np.where(fall, -1, np.where(rise, 1, direction)).astype(np.int8)
            low = np.where(fall, v, low)
            high = np.where(rise, v, high)
            change = fall | rise
            slot = t % window
            running += change.astype(np.int16) - recent[slot]
            recent[slot] = change
            np.maximum(best, running, out=best)
        most[rows] = best
    return most


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames", nargs="+", help="frame paths or a quoted PNG glob")
    parser.add_argument("--fps", type=float, required=True, help="the rate the sequence was rendered at")
    parser.add_argument("--step", type=int, default=4,
                        help="sample every Nth row and column (1 checks every pixel; above 1 is an estimate)")
    parser.add_argument("--motion", action="store_true", help="report mean absolute change and save a peak heat map")
    args = parser.parse_args()
    if not math.isfinite(args.fps) or args.fps < 8 or args.step < 1:
        parser.error("--fps must be at least 8 (to see four flashes in a second) and --step positive")

    paths = {Path(name) for pattern in args.frames for name in glob.glob(pattern)}
    paths = [p for p in paths if not p.name.endswith("-flicker.png")]
    if not paths:
        parser.error("no frames matched")
    paths.sort(key=lambda p: [int(s) if s.isdigit() else s for s in re.split(r"(\d+)", str(p))])
    parts = [(p.parent, m.group(1), int(m.group(2))) for p in paths if (m := re.fullmatch(r"(.*)-(\d+)\.png", p.name))]
    numbers = [number for _, _, number in parts]
    if (len(parts) != len(paths) or len({(folder, stem) for folder, stem, _ in parts}) != 1
            or numbers != list(range(numbers[0], numbers[0] + len(numbers)))):
        parser.error("frames must be one consecutive numbered sequence (name-0000.png, name-0001.png, …)")
    trim = math.ceil(args.fps / 2)
    if len(paths) - 2 * trim < MINIMUM_SECONDS * args.fps:
        parser.error(f"need {MINIMUM_SECONDS} s after trimming 0.5 s at each end, got {len(paths)} frames")

    with Image.open(paths[0]) as first:
        size = first.size
    width, height = (len(range(0, n, args.step)) for n in size)
    # On disk, so a full-resolution check of a long capture does not need it all in memory.
    store = tempfile.NamedTemporaryFile(suffix=".npy")
    frames = np.lib.format.open_memmap(store.name, mode="w+", dtype=np.float32, shape=(len(paths), height, width))
    for i, path in enumerate(paths):
        frames[i] = luminance(path, args.step, size)

    # Transform one sampled row at a time to bound FFT scratch space.
    # Mirror each series before the FFT: the FFT treats a series as periodic, and the jump from
    # the last frame back to the first would otherwise count as flicker.
    count = 2 * len(paths)
    bin_width = args.fps / count
    low_bins = np.arange(count // 2 + 1) * bin_width < 3 - 2 * bin_width
    peaks = np.empty((height, width), dtype=np.float32)
    motion = 0.0
    for y in range(height):
        row = frames[:, y, :]
        spectrum = np.fft.rfft(np.concatenate([row, row[::-1]]), axis=0)
        spectrum[low_bins] = 0
        residual = np.fft.irfft(spectrum, n=count, axis=0)[:len(paths)]
        peaks[y] = np.max(np.abs(residual[trim:-trim]), axis=0)
        if args.motion:
            motion += np.mean(np.abs(np.diff(row, axis=0)), dtype=np.float64)

    changes = most_changes_per_second(frames, args.fps)
    flashes = np.floor(changes / 2)  # completed pairs: a change and its return
    worst_flashes = float(flashes.max())
    print(f"most flashes in any second at one pixel: {worst_flashes:g} (limit {FLASHES_PER_SECOND})")
    print(f"fraction of pixels over the limit: {np.mean(flashes > FLASHES_PER_SECOND):.8f}")

    worst = peaks.max()
    if args.step > 1:
        print(f"sampled every {args.step} pixels: an estimate (exit 2 if nothing found); --step 1 to pass or fail")
    p999, p99 = np.percentile(peaks, [99.9, 99])
    print("for reference, the luminance changing above 3 Hz:")
    print(f"worst peak (SDR white): {worst:.8f}")
    print(f"99.9th percentile peak (SDR white): {p999:.8f}")
    print(f"99th percentile peak (SDR white): {p99:.8f}")
    print(f"fraction of pixels above {LIMIT}: {np.mean(peaks > LIMIT):.8f}")
    if args.motion:
        print(f"mean absolute frame-to-frame change (SDR white): {motion / height:.8f}")
        heat = Image.fromarray(np.rint(np.minimum(peaks / LIMIT, 1) * 255).astype(np.uint8))
        heat.thumbnail((512, 512))
        heat.save(paths[0].with_name(paths[0].stem + "-flicker.png"))
    if worst_flashes > FLASHES_PER_SECOND:
        return 1
    # A sampled run that finds nothing has not checked every pixel.
    return 2 if args.step > 1 else 0


if __name__ == "__main__":
    raise SystemExit(main())

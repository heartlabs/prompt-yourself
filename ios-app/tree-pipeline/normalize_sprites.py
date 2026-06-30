#!/usr/bin/env python3
"""
normalize_sprites.py — bake leaf sprites into the app's fixed convention.

Each sprite is rewritten so it is:
  * upright            — petiole -> apex points straight UP
  * stem at bottom-centre  -> the app hardcodes stem = (0.5, 1.0), no per-sprite data
  * speck-free         — only the largest opaque blob is kept

So you can feed in leaves drawn at ANY angle (e.g. straight from an image model,
after keying out the background) and they come out drop-in ready.

Usage:
  python3 normalize_sprites.py --dir art/leaves_elongated        # in place (+ _orig backup)
  python3 normalize_sprites.py --dir art/leaves_elongated --out art/leaves_norm
  python3 normalize_sprites.py --file leaf.png --out out/         # single file

Input sprites must be TRANSPARENT PNGs (background already removed). To key a
solid-magenta background to transparency first, see README ("keying").
"""
import argparse
import glob
import os
import shutil

import numpy as np
from PIL import Image

from treelib import clean_largest, detect_stem


def normalize(path, bottom_pad=1, side_pad=4, top_pad=4):
    """Return a normalized RGBA Image: upright, stem at bottom-centre."""
    im = Image.open(path).convert("RGBA")
    arr = clean_largest(np.asarray(im))
    sp = Image.fromarray(arr)
    (sx, sy), blade = detect_stem(sp)                     # blade = stem->apex (deg cw from up)

    # Make the blade point straight up, keeping the stem at the buffer centre.
    side = int(max(sp.width, sp.height) * 2.8)
    cc = side // 2
    big = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    big.alpha_composite(sp, (int(cc - sx), int(cc - sy)))
    big = big.rotate(blade, resample=Image.BICUBIC, center=(cc, cc))

    a = np.asarray(big)[..., 3]
    ys, xs = np.where(a > 20)
    xmin, xmax, ymin = int(xs.min()), int(xs.max()), int(ys.min())
    half_w = max(cc - xmin, xmax - cc) + side_pad
    left, right = cc - half_w, cc + half_w                # stem horizontally centred
    top, bottom = ymin - top_pad, cc + bottom_pad         # stem on the bottom row
    return big.crop((left, top, right, bottom))           # stem now at (0.5, ~1.0)


def main():
    ap = argparse.ArgumentParser(description="Normalize leaf sprites to upright / stem-bottom-centre.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dir", help="folder of *.png sprites to normalize")
    g.add_argument("--file", help="a single sprite PNG to normalize")
    ap.add_argument("--out", help="output folder (default: in place, with a *_orig backup)")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "*.png"))) if args.dir else [args.file]
    if not files:
        print("no PNGs found"); return

    in_place = args.out is None
    if in_place and args.dir:
        backup = args.dir.rstrip("/") + "_orig"
        os.makedirs(backup, exist_ok=True)
    elif args.out:
        os.makedirs(args.out, exist_ok=True)

    for p in files:
        out_img = normalize(p)
        if in_place:
            if args.dir:
                b = os.path.join(args.dir.rstrip("/") + "_orig", os.path.basename(p))
                if not os.path.exists(b):
                    shutil.copy(p, b)
            dst = p
        else:
            dst = os.path.join(args.out, os.path.basename(p))
        out_img.save(dst)
        print(f"normalized {os.path.basename(p)} -> {dst}  ({out_img.width}x{out_img.height})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
key_magenta.py — turn a solid-magenta background into transparency.

Image models won't reliably output true transparency, so the robust path is to
generate each leaf on a solid magenta (#FF00FF) background and key it out here.

Usage:
  python3 key_magenta.py --file raw_leaf.png --out keyed/leaf.png
  python3 key_magenta.py --dir raw_leaves --out keyed       # all *.png in a folder
"""
import argparse
import glob
import os

import numpy as np
from PIL import Image


def key(path, out_path):
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im).astype(np.int32)
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    # magenta = high red, high blue, distinctly lower green
    magenta = (R > 120) & (B > 110) & (G < R - 30) & (G < B - 30)
    a[..., 3] = np.where(magenta, 0, 255)
    Image.fromarray(a.astype(np.uint8)).save(out_path)


def main():
    ap = argparse.ArgumentParser(description="Key a solid-magenta background to transparency.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--file")
    g.add_argument("--dir")
    ap.add_argument("--out", required=True, help="output file (with --file) or folder (with --dir)")
    args = ap.parse_args()

    if args.file:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        key(args.file, args.out)
        print(f"keyed {args.file} -> {args.out}")
    else:
        os.makedirs(args.out, exist_ok=True)
        for p in sorted(glob.glob(os.path.join(args.dir, "*.png"))):
            dst = os.path.join(args.out, os.path.basename(p))
            key(p, dst)
            print(f"keyed {os.path.basename(p)} -> {dst}")


if __name__ == "__main__":
    main()

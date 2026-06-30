#!/usr/bin/env python3
"""
render_tree.py — local preview of the tree (the same look the iOS app produces).

Reads anchors.json + a leaf-sprite folder, draws the trunk, then per zone draws
the first N anchors (N = round(zone_count * score/100)), each leaf placed with
its stem on the anchor and rotated to the anchor angle, tinted by the
probabilistic tone model. Use it to eyeball changes before building in Xcode.

Usage:
  python3 render_tree.py --scores 72,78,68,80
  python3 render_tree.py --scores 100,100,100,100 --leaves art/leaves_elongated --out /tmp/tree.png
  python3 render_tree.py --scores 20,85,35,15 --trunk art/trunk.png --anchors anchors/anchors.json

Scores are UL,UR,LL,LR (About Me, Work & Goals, Family & Relationships, Social Life).
"""
import argparse
import glob
import json
import os
from collections import defaultdict

import numpy as np
from PIL import Image

from treelib import detect_stem, place_leaf, tone_for, IVORY

ZI = {"UL": 0, "UR": 1, "LL": 2, "LR": 3}


def load_sprites(leaves_dir):
    """tone -> [(Image, (stem_x,stem_y), blade_deg)] for variants present in the folder."""
    sprites = {}
    for tone in ("deep", "medium", "pale"):
        items = []
        for p in sorted(glob.glob(os.path.join(leaves_dir, f"leaf_{tone}_*.png"))):
            im = Image.open(p).convert("RGBA")
            items.append((im, *detect_stem(im)))
        sprites[tone] = items
    return sprites


def main():
    ap = argparse.ArgumentParser(description="Render a preview tree from anchors + sprites.")
    ap.add_argument("--scores", default="72,78,68,80", help="UL,UR,LL,LR each 0..100")
    ap.add_argument("--trunk", default="art/trunk.png")
    ap.add_argument("--anchors", default="anchors/anchors.json")
    ap.add_argument("--leaves", default="art/leaves_elongated")
    ap.add_argument("--out", default="/tmp/tree_preview.png")
    ap.add_argument("--leaf-frac", type=float, default=None, help="leaf height as fraction of trunk height")
    ap.add_argument("--variety", type=float, default=0.15,
                    help="tone variety 0..1: chance of lighter shades even at high scores (0 = none)")
    ap.add_argument("--seedbase", type=int, default=13)
    args = ap.parse_args()

    doc = json.load(open(args.anchors))
    W, H = int(doc["trunk_w"]), int(doc["trunk_h"])
    trunk = Image.open(args.trunk).convert("RGBA")
    sprites = load_sprites(args.leaves)
    leaf_frac = args.leaf_frac if args.leaf_frac is not None else (
        0.058 if "elongated" in args.leaves else 0.045)

    ul, ur, ll, lr = [float(x) for x in args.scores.split(",")]
    scores = {"UL": ul, "UR": ur, "LL": ll, "LR": lr}

    # all-side margins so outward leaves aren't clipped (matches the app)
    mx, myt, myb = int(W * 0.06), int(H * 0.07), int(H * 0.04)
    cv = Image.new("RGBA", (W + 2 * mx, H + myt + myb), IVORY + (255,))
    cv.alpha_composite(trunk, (mx, myt))

    zones = defaultdict(list)
    for a in doc["anchors"]:
        zones[a["zone"]].append(a)

    for z, anks in zones.items():
        s = scores[z]
        n = int(round(len(anks) * s / 100.0))
        zi = ZI[z]
        for i in range(n):
            a = anks[i]
            seed = zi * 100003 + i * 97 + args.seedbase
            rl = np.random.default_rng(seed)
            tone = tone_for(s, seed, variety=args.variety)
            variants = sprites[tone]
            if not variants:
                continue
            k = int(rl.integers(0, len(variants)))
            spr, (stx, sty), sang = variants[k]
            lh = H * leaf_frac * (0.85 + 0.3 * rl.random())
            sc = lh / spr.height
            place_leaf(cv, spr, (stx, sty), sang, (a["x"] * W + mx, a["y"] * H + myt), a["rot"], sc)

    cv.convert("RGB").save(args.out)
    counts = {z: int(round(len(zones[z]) * scores[z] / 100.0)) for z in zones}
    print(f"wrote {args.out}  scores={scores}  leaves drawn per zone={counts}")


if __name__ == "__main__":
    main()

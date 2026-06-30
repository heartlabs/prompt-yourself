#!/usr/bin/env python3
"""
make_anchors.py — turn a painted tree-trunk PNG into anchors.json for the app.

What it does:
  trunk.png -> branch mask -> distance transform (thickness) -> skeleton ->
  twig tips + geodesic growth flow -> leaf anchors (tip + both branch edges),
  each with an outward rotation. Writes anchors.json (normalized coords).

Usage:
  python3 make_anchors.py                                   # art/trunk.png -> anchors/anchors.json
  python3 make_anchors.py --trunk art/trunk.png --out anchors/anchors.json
  python3 make_anchors.py --debug                           # also write debug images
  python3 make_anchors.py --splay 28 --step 26 --twig-max 24 --min-a 20

Debug images (with --debug, written next to --out):
  debug_skeleton.png   branch mask + skeleton centrelines + twig tips
  debug_arrows.png     trunk + a red arrow per anchor (the leaf direction)

The app reads only anchors.json; the debug images are for you.
"""
import argparse
import json
import os

from treelib import Tree


def main():
    ap = argparse.ArgumentParser(description="Generate leaf anchors from a tree-trunk PNG.")
    ap.add_argument("--trunk", default="art/trunk.png", help="input trunk PNG (transparent bg)")
    ap.add_argument("--out", default="anchors/anchors.json", help="output anchors JSON path")
    ap.add_argument("--debug", action="store_true", help="also write debug_skeleton.png / debug_arrows.png")
    # geometry / orientation parameters
    ap.add_argument("--splay", type=float, default=30.0, help="edge-leaf tilt off the twig axis (deg)")
    ap.add_argument("--twig-max", type=float, default=24.0, help="max branch radius that bears leaves (px)")
    ap.add_argument("--step", type=float, default=40.0, help="spacing of samples along branches (px)")
    ap.add_argument("--min-a", type=float, default=28.0, help="min spacing between anchors (px)")
    args = ap.parse_args()

    tree = Tree(args.trunk, twig_max=args.twig_max, splay=args.splay, step=args.step, min_a=args.min_a)
    anchors = tree.gen_anchors()

    from collections import Counter
    by_zone = dict(Counter(a["zone"] for a in anchors))

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    doc = {
        "image": os.path.basename(args.trunk),
        "trunk_w": int(tree.W),
        "trunk_h": int(tree.H),
        "coords": "x,y normalized 0..1 of trunk image; rot = deg clockwise from straight-up; "
                  "zone in {UL,UR,LL,LR}; tip = 1 if at a twig tip",
        "method": "procedural: tip leaves point along the twig; edge leaves on the silhouette "
                  "point the twig growth direction +/- splay toward their edge; growth direction "
                  "from geodesic flow along the skeleton",
        "params": {"splay_deg": args.splay, "twig_max": args.twig_max, "step": args.step, "min_a": args.min_a},
        "count": len(anchors),
        "anchors": anchors,
    }
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {args.out}: {len(anchors)} anchors  by zone {by_zone}")

    if args.debug:
        outdir = os.path.dirname(args.out) or "."
        sk = os.path.join(outdir, "debug_skeleton.png")
        ar = os.path.join(outdir, "debug_arrows.png")
        tree.draw_skeleton().save(sk)
        tree.draw_arrows(anchors).save(ar)
        print(f"wrote {sk}\nwrote {ar}")


if __name__ == "__main__":
    main()

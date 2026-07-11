#!/usr/bin/env python3
"""
make_goal_sprites.py — turn the 6 solid-magenta goal-growth renders into
clean, transparent, consistently-framed PNGs for the Goal cards.

Pipeline per stage:
  1. Soft chroma-key the magenta/pink background -> alpha (feathered edges).
  2. Despill: pull the pink fringe out of kept edge pixels.
  3. Trim to the alpha bounding box.
  4. Scale to a per-stage target height (a growth ramp) and place onto a
     square transparent canvas, horizontally centred, sharing one baseline.

Output: goal_sprites/goal_growth_{0..5}.png
"""
import numpy as np
from PIL import Image

SRC = "goal_raw"
OUT = "goal_sprites"
CANVAS = 768                 # square output size (px)
BASELINE_FRAC = 0.99         # where the bottom of the plant sits (fraction of canvas)
SIDE_MARGIN = 0.98           # max content width as a fraction of the canvas
# Every stage is "zoomed in" to nearly fill the canvas height so the plant
# reads at full card height in all stages (growth shows through FORM, not
# size). A whisper of a ramp keeps a subtle sense of progression.
HEIGHT_FRAC = [0.86, 0.90, 0.93, 0.96, 0.98, 1.00]
ALPHA_THRESH = 18            # alpha considered "content" for bbox
import os
os.makedirs(OUT, exist_ok=True)


def key_and_despill(path):
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    # "magenta-ness": how much red AND blue exceed green (pink/magenta bg).
    score = np.minimum(R - G, B - G)
    # Soft alpha ramp: score<=lo fully opaque, score>=hi fully transparent.
    lo, hi = 28.0, 80.0
    alpha = 1.0 - np.clip((score - lo) / (hi - lo), 0.0, 1.0)
    alpha = np.clip(alpha, 0.0, 1.0)
    # Despill: neutralise pink fringe by pulling R and B down toward G by the
    # positive magenta excess (leaves greens, browns, creams untouched).
    m = np.clip(np.minimum(R - G, B - G), 0.0, None)
    R2 = R - m
    B2 = B - m
    out = np.stack([R2, G, B2, alpha * 255.0], axis=-1)
    out = np.clip(out, 0, 255).astype(np.uint8)
    # Fully drop near-transparent pixels so no faint pink haze remains.
    out[..., 3] = np.where(out[..., 3] < 8, 0, out[..., 3])
    return Image.fromarray(out, "RGBA")


def bbox(im, thresh=ALPHA_THRESH):
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a > thresh)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def normalize(im, height_frac):
    b = bbox(im)
    im = im.crop(b)
    w, h = im.size
    target_h = height_frac * CANVAS
    scale = target_h / h
    # Don't let it exceed the canvas width.
    max_w = SIDE_MARGIN * CANVAS
    if w * scale > max_w:
        scale = max_w / w
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - nw) // 2
    baseline = int(CANVAS * BASELINE_FRAC)
    y = baseline - nh
    canvas.alpha_composite(im, (x, max(0, y)))
    return canvas


for i in range(6):
    keyed = key_and_despill(f"{SRC}/stage{i}.png")
    norm = normalize(keyed, HEIGHT_FRAC[i])
    norm.save(f"{OUT}/goal_growth_{i}.png")
    print(f"stage{i}: bbox={bbox(keyed)} -> {OUT}/goal_growth_{i}.png")
print("done")

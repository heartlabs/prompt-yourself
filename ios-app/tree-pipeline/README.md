# "Your Life" Tree — Art Pipeline

This folder is the **local, runnable pipeline** that turns painted artwork into the
two things the HeartlabsEcho iOS app needs to draw the life-tree:

1. **`anchors.json`** — where every leaf attaches to the trunk and which way it points.
2. **Normalized leaf sprite PNGs** — leaves in a fixed pose the app can stamp without any per‑sprite data.

The iOS app does **zero** image analysis at runtime: it loads `anchors.json`, draws the
trunk, and for each leaf stamps a sprite (stem on the anchor, rotated to the anchor angle).
All the heavy lifting (skeletons, distance transforms, geodesic flow, stem detection) happens
**here, once, offline**.

---

## Contents

```
README.md              this file
requirements.txt       Python deps
treelib.py             shared core: Tree geometry + sprite helpers (imported by the scripts)

make_anchors.py        trunk.png  -> anchors.json   (+ optional debug images)
normalize_sprites.py   raw leaf PNGs -> upright, stem-at-bottom-centre sprites
key_magenta.py         magenta-background PNG -> transparent PNG
render_tree.py         local preview: anchors.json + sprites -> a rendered tree PNG

art/
  trunk.png            the painted bare tree (transparent background, with ground shadow)
  leaves_elongated/    12 leaf sprites: leaf_{deep,medium,pale}_{1..4}.png  (the app default)
  leaves_round/         9 leaf sprites: leaf_{deep,medium,pale}_{1..3}.png  (alt build-flag set)
anchors/
  anchors.json         example baked output (regenerate with make_anchors.py)
```

## Setup

```bash
pip install -r requirements.txt          # pillow numpy scipy scikit-image
```

Everything runs with `python3`. No app/Xcode needed — this is pure Python.

## Preconditions (important)

The anchor generator assumes the trunk artwork is **brown wood on a transparent background**:

- **Transparent background (alpha).** The image must be a PNG with a real alpha channel; the
  tree pixels opaque, everything else transparent. If your art comes on a solid background,
  remove it first (e.g. generate on solid magenta and run `key_magenta.py`).
- **Brown wood.** The branch mask keys on "red > blue" (`R > B + 8`), which isolates brown
  wood and conveniently rejects a grey ground shadow. A black/green/grey silhouette, or a
  trunk tinted toward blue, will **not** be detected without changing the mask in `treelib.py`.
- **Upright, rooted at the bottom.** The growth direction flows outward from the lowest
  skeleton pixel (the trunk base).
- **Four branch masses, roughly one per quadrant** (upper-left / upper-right / lower-left /
  lower-right), centered horizontally — because the feature maps four life categories onto
  the four zones `UL/UR/LL/LR`.

A soft grey ground shadow is fine (it's rejected by the mask). Leaf sprites are separate art and
have their own rules (see "Generating new leaf sprites").

---

## The pipeline at a glance

```
            (image model)                 key_magenta.py            normalize_sprites.py
 prompt  ───────────────►  raw leaf PNGs ───────────────►  transparent PNGs ───────────────►  normalized sprites ──┐
                            (magenta bg)                                                        (upright, stem      │
                                                                                                 bottom-centre)     │
                                                                                                                    ▼
 trunk.png  ───────────────────────────────────────────────────────────────────────────────────►  make_anchors.py ──►  anchors.json
                                                                                                                    │
                                                                            render_tree.py  ◄───────────────────────┘
                                                                            (preview before shipping to the app)
```

You only re-run the parts that changed:
- **New/changed leaves?** key (if needed) → normalize → drop into `art/leaves_*`. (No need to touch anchors.)
- **New/changed trunk?** re-run `make_anchors.py`.

---

## Scripts

### `make_anchors.py` — trunk → anchors.json

```bash
python3 make_anchors.py                       # art/trunk.png -> anchors/anchors.json
python3 make_anchors.py --debug               # + debug_skeleton.png, debug_arrows.png
python3 make_anchors.py --trunk art/trunk.png --out anchors/anchors.json
python3 make_anchors.py --splay 28 --step 26 --twig-max 24 --min-a 20
```

**How it works:** threshold the brown wood → distance transform (branch thickness) →
skeleton (centrelines) → twig tips → geodesic distance from the root along the skeleton
(this gives each point its true *outward growth direction*). Then it places anchors:

- **Tip leaves:** one at every twig tip, pointing **along the twig**.
- **Edge leaves:** sampled along the branch **silhouette** (both sides); each points the
  twig growth direction **± `splay`°** toward its own edge — so left‑edge leaves tilt left,
  right‑edge leaves tilt right, always fanning outward.

**All flags:**

| flag | default | meaning |
|---|---|---|
| `--trunk` | `art/trunk.png` | input trunk PNG (must be brown wood on a transparent background — see Preconditions) |
| `--out` | `anchors/anchors.json` | output anchors JSON path |
| `--debug` | off | also write `debug_skeleton.png` and `debug_arrows.png` next to `--out` |
| `--splay` | `30` | degrees an edge leaf tilts off the twig axis, toward its edge |
| `--twig-max` | `24` | max branch *radius* (px) that bears leaves — excludes the thick trunk. **Scales with image resolution**, so a much larger/smaller trunk image needs this adjusted |
| `--step` | `40` | spacing (px) of samples along branches — **larger ⇒ fewer, sparser leaves** |
| `--min-a` | `28` | minimum spacing (px) between final anchors (dedupe) |

`make_anchors.py` only reads the **trunk** — it has nothing to do with the leaf sprites, so the
leaf set you ship is independent of the anchors.

**Output `anchors.json`:** `{ trunk_w, trunk_h, count, anchors: [ {x, y, rot, zone, tip} ] }`
where `x,y` are normalized 0–1 of the trunk image, `rot` is degrees clockwise from straight‑up,
`zone` ∈ `{UL,UR,LL,LR}`, `tip` is 1 at a twig tip. **Array order is the reveal order** (low
scores reveal the first N per zone), so don't reshuffle it.

**Debug images** (`--debug`): `debug_skeleton.png` (grey branch mask + green centrelines + red
twig tips) and `debug_arrows.png` (trunk + a green stem dot and red direction arrow per anchor).

### `normalize_sprites.py` — make leaves conform

```bash
python3 normalize_sprites.py --dir art/leaves_elongated         # in place (keeps a *_orig backup)
python3 normalize_sprites.py --dir art/leaves_elongated --out art/leaves_norm
python3 normalize_sprites.py --file leaf.png --out out/
```

Rewrites each sprite to the app's fixed convention:
- **upright** — petiole→apex points straight up,
- **stem at bottom‑centre** — so the app hardcodes `stem = (0.5, 1.0)`, no per‑sprite file,
- **speck‑free** — only the largest opaque blob is kept (drops cutting artifacts).

Input must be a **transparent** PNG. Orientation/curl of the input don't matter — that's the
whole point. (It detects the stem once, here, and bakes the rotation into the PNG.)

### `key_magenta.py` — magenta background → transparent

```bash
python3 key_magenta.py --file raw_leaf.png --out keyed/leaf.png
python3 key_magenta.py --dir raw_leaves --out keyed
```

Image models don't reliably output true transparency, so generate leaves on a **solid magenta
(`#FF00FF`)** background and key it out here.

### `render_tree.py` — local preview

```bash
python3 render_tree.py --scores 72,78,68,80
python3 render_tree.py --scores 100,100,100,100 --leaves art/leaves_elongated --out /tmp/tree.png
python3 render_tree.py --scores 20,85,35,15
```

Renders the same look the app produces (trunk + first‑N leaves per zone, tinted by the
probabilistic tone model). Use it to eyeball changes before building in Xcode.

| flag | default | meaning |
|---|---|---|
| `--scores` | `72,78,68,80` | `UL,UR,LL,LR` = About Me, Work & Goals, Family & Relationships, Social Life (each 0–100) |
| `--trunk` | `art/trunk.png` | trunk PNG to draw |
| `--anchors` | `anchors/anchors.json` | anchors file to read |
| `--leaves` | `art/leaves_elongated` | **which leaf-sprite folder to use** (see below) |
| `--out` | `/tmp/tree_preview.png` | output image path |
| `--leaf-frac` | auto | leaf height as a fraction of trunk height (auto: `0.058` if the folder name contains "elongated", else `0.045`) |
| `--variety` | `0.15` | tone variety 0–1: chance of lighter shades even at high scores (0 = pure score-driven). Matches the app's `LeafConvention.toneVariety` |
| `--seedbase` | `13` | seed offset for the per-leaf tone/variant RNG |

### Which leaf set gets used?

There is **no auto-detection** — it's chosen explicitly, in two different places:

- **In this pipeline (preview):** you pass the folder with `--leaves`. Point it at
  `art/leaves_elongated`, `art/leaves_round`, or any folder of `leaf_<tone>_<n>.png` sprites.
- **In the iOS app:** a compile-time flag picks the set. `LeafStyle.current` in
  `LifeTreeModels.swift` is `.elongated` or `.round`, and the renderer builds asset names as
  `leaf_<style>_<tone>_<n>` (e.g. `leaf_elongated_deep_1`). So the *folder name here* maps to
  the *style prefix there*. To add a brand-new set (say "willow"): add a `case willow` to
  `LeafStyle` (with its `variantsPerTone` and `leafHeightFraction`), ship the sprites as
  `leaf_willow_<tone>_<n>` imagesets, and set `LeafStyle.current = .willow`.

---

## Generating new leaf sprites with an AI

You can replace the leaves entirely. The normalizer fixes pose, so you only have to get the
*content* and *background* right.

**Prompt template** (run once per leaf; vary the **bold** parts):

> "A single hand‑painted leaf, soft gouache/watercolor wellness‑app style, **deep sage green**
> *(or medium sage / pale sage‑cream)*, gently curved **lanceolate** shape with a subtle midrib
> and faint veins, soft matte edges, flat even lighting, no shadow, a short thin brown
> **stem/petiole** at its base, the whole leaf centered with margin, on a solid pure magenta
> (`#FF00FF`) background."

**Rules for a conforming sprite:**
1. **One leaf, fully in frame, with a visible stalk.** The normalizer uses the stalk to find the petiole; no stalk ⇒ it may pick the wrong end.
2. **Solid magenta background** (so `key_magenta.py` can cut it cleanly). Avoid magenta/pink *in* the leaf.
3. **Generate all three tones** — `deep`, `medium`, `pale` — because the app mixes them by score (greener = higher score). Aim for a clear dark‑sage / mid‑sage / pale‑cream spread.
4. **Variety helps** — a few shapes/sizes per tone keeps the canopy from looking stamped.
5. Orientation, curl, and exact size **don't matter** — `normalize_sprites.py` handles them.

**Then wire them in:**

```bash
# 1. key out the magenta background
python3 key_magenta.py --dir raw_leaves --out keyed
# 2. normalize to the app convention
python3 normalize_sprites.py --dir keyed --out art/leaves_elongated
# 3. (rename if needed) the app expects:  leaf_<tone>_<n>.png   e.g. leaf_deep_1.png ... leaf_deep_4.png
# 4. preview
python3 render_tree.py --scores 72,78,68,80
```

Folder + naming the app expects: `art/leaves_<style>/leaf_<tone>_<n>.png`, where `style` ∈
`{elongated, round}`, `tone` ∈ `{deep, medium, pale}`, `n` = 1…N. If you change **N** (variants
per tone), update `LeafStyle.variantsPerTone` in the iOS app (`LifeTreeModels.swift`).

---

## Updating the assets in the iOS app — step by step

All app assets live under `ios-app/HeartlabsEcho/`. Two kinds of resource are involved:
`anchors.json` (a plain bundle file, already registered in the Xcode project) and the images
in `Assets.xcassets/` (a **folder reference** — Xcode picks up files dropped in, no project
edits needed). The app needs **no `leaf_stems.json`**: sprites are pre-normalized, so the
renderer hardcodes `stem = (0.5, 1.0)` and reads each image's width/height for proportions.

### A. Update the anchors

1. Re-bake: `python3 make_anchors.py --trunk art/trunk.png --out anchors/anchors.json`.
2. Copy it over the app's copy: `ios-app/HeartlabsEcho/anchors.json`.
   (It's already in the project's Resources, so no `.pbxproj` edit — just overwrite the file.)

### B. Update the trunk image

1. The trunk imageset is `ios-app/HeartlabsEcho/Assets.xcassets/trunk.imageset/`. It contains
   `Contents.json` + the PNG.
2. Replace the PNG with your new `trunk.png`, **keeping the filename** referenced in that
   folder's `Contents.json` (or update the `filename` field to match).

### C. Update / replace leaf sprites

Each sprite is its own imageset: `Assets.xcassets/leaf_<style>_<tone>_<n>.imageset/` containing
`Contents.json` + `leaf_<tone>_<n>.png`. The imageset **name** carries the style prefix; the
**file inside** keeps the short `leaf_<tone>_<n>.png` name.

- **Swapping art (same count):** normalize the new sprites, then overwrite the PNG inside each
  existing `.imageset` folder (match the existing filename). Done — no project edits.
- **Adding a new imageset** (new variant, or a brand-new style): create a folder
  `leaf_<style>_<tone>_<n>.imageset/`, drop the PNG in, and add a `Contents.json`:
  ```json
  {
    "images": [{ "idiom": "universal", "filename": "leaf_deep_1.png" }],
    "info": { "version": 1, "author": "xcode" },
    "properties": { "preserves-vector-representation": false }
  }
  ```
  (Single-scale universal — that's all these flat PNGs need.)

### D. If the variant count or style changed (Swift edit)

- Changed **how many variants per tone** (e.g. 4 → 5 elongated): update
  `LeafStyle.variantsPerTone` in `LifeTreeModels.swift`.
- Added a **new style** (e.g. "willow"): add a `case willow` to `LeafStyle` with its
  `variantsPerTone` and `leafHeightFraction`, ship `leaf_willow_<tone>_<n>` imagesets, and set
  `LeafStyle.current = .willow`. (No `.pbxproj` edit — images are folder-referenced.)

### E. Rebuild

In Xcode: **Product → Clean Build Folder** (⇧⌘K), then **Build** (⌘B), so the asset catalog
recompiles with the new images. Open the **Tree** tab (or the DEBUG score sliders) to verify.

> When is a `project.pbxproj` edit needed? Only for **new Swift files** or **new non-asset
> bundle files**. Image swaps inside `Assets.xcassets` and overwriting the existing
> `anchors.json` never require one.

---

## Notes / conventions

- **Coordinates:** `rot` and all sprite angles are **degrees clockwise from straight‑up** (screen space, y‑down).
- **Tones:** per leaf, `deep = (score/100)^1.6`, `pale = (1 − score/100)^1.6`, `medium` = the remainder — so higher score ⇒ greener, every zone a natural mix. The `--variety` knob (default `0.15`) blends in a uniform baseline so a few lighter leaves persist even at score 100; keep it equal to the app's `LeafConvention.toneVariety`.
- **Determinism:** the Python preview uses NumPy's RNG; the app uses a small SplitMix64 with the *same* per‑leaf seed and tone thresholds. The per‑leaf variant/tint won't be pixel‑identical between the two, but the placement, density, and statistical mix are.
- **Reproducing the trunk geometry:** `treelib.Tree` recomputes everything from `trunk.png`. If you repaint the trunk, keep it a transparent PNG with brown wood (the mask keys on "red > blue", which also rejects the grey ground shadow).

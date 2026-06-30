"""
treelib.py — shared core for the "Your Life" tree pipeline.

Contains:
  * sprite helpers     : clean_largest, detect_stem, place_leaf, tone_for
  * the Tree class     : trunk-image geometry (branch mask -> distance transform ->
                         skeleton -> tips -> geodesic flow) and the procedural
                         leaf-anchor generator, plus debug renderers.

Nothing here runs at import time; you build a Tree from a trunk PNG path:

    from treelib import Tree
    tree = Tree("art/trunk.png")
    anchors = tree.gen_anchors()          # list of dicts {x,y,rot,zone,tip}

Requires: pillow numpy scipy scikit-image   (see requirements.txt)
"""
import math
from collections import deque

import numpy as np
from PIL import Image, ImageDraw
from skimage.morphology import skeletonize, remove_small_holes, remove_small_objects
from scipy import ndimage
from scipy.spatial import cKDTree

IVORY = (245, 242, 235)


# ======================================================================
#  Sprite helpers (operate on individual leaf PNGs; no trunk needed)
# ======================================================================

def clean_largest(arr):
    """Zero the alpha of everything except the largest opaque blob (drops cut specks)."""
    A = arr[..., 3]
    mask = A > 20
    lbl, n = ndimage.label(mask)
    if n > 1:
        sizes = ndimage.sum(np.ones_like(lbl), lbl, range(1, n + 1))
        keep = 1 + int(np.argmax(sizes))
        arr = arr.copy()
        arr[(lbl != keep) & mask, 3] = 0
    return arr


def detect_stem(im):
    """Locate a leaf sprite's stem (petiole) pixel and its blade angle.

    stem  = far-from-centroid + thin + low pixel of the largest blob.
    blade = direction stem -> apex (farthest pixel), in degrees clockwise from up.
    For a NORMALIZED sprite (upright, stem at bottom-centre) this returns
    ~(0.5*w, 1.0*h) and ~0 degrees.
    """
    A = np.asarray(im)[..., 3]
    mask = A > 40
    lbl, nl = ndimage.label(mask)
    if nl > 1:
        sizes = ndimage.sum(np.ones_like(lbl), lbl, range(1, nl + 1))
        mask = (lbl == 1 + int(np.argmax(sizes)))
    dt = ndimage.distance_transform_edt(mask)
    ys, xs = np.where(mask)
    cx, cy = xs.mean(), ys.mean()
    dn = np.hypot(xs - cx, ys - cy)
    dn = dn / (dn.max() + 1e-9)
    dtn = dt[ys, xs] / (dt.max() + 1e-9)
    yn = (ys - ys.min()) / (ys.max() - ys.min() + 1e-9)
    score = 0.7 * dn - 0.8 * dtn + 1.0 * yn           # far + thin + toward bottom
    i = int(np.argmax(score))
    sx, sy = xs[i], ys[i]
    dd = (xs - sx).astype(np.int64) ** 2 + (ys - sy).astype(np.int64) ** 2
    j = int(np.argmax(dd))                            # apex = farthest pixel from stem
    tx, ty = xs[j], ys[j]
    return (float(sx), float(sy)), math.degrees(math.atan2(tx - sx, -(ty - sy)))


def place_leaf(canvas, sprite, stem_xy, sprite_ang, anchor, target_rot, scale):
    """Rotate `sprite` about its stem so the stem lands on `anchor` and the blade
    points at `target_rot` (deg clockwise from up); alpha-composite onto `canvas`."""
    sp = sprite.resize((max(1, int(sprite.width * scale)), max(1, int(sprite.height * scale))),
                       Image.BICUBIC)
    sx, sy = stem_xy[0] * scale, stem_xy[1] * scale
    side = int(max(sp.width, sp.height) * 2.8)         # buffer: corner stems reach ~1.2x diagonal
    cc = side // 2
    big = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    big.alpha_composite(sp, (int(cc - sx), int(cc - sy)))
    big = big.rotate(-(target_rot - sprite_ang), resample=Image.BICUBIC, center=(cc, cc))
    canvas.alpha_composite(big, (int(anchor[0] - cc), int(anchor[1] - cc)))


def tone_for(score, seed, variety=0.0):
    """Probabilistic per-leaf tone. deep = s^1.6, pale = (1-s)^1.6, medium = rest.

    `variety` (0..1) blends the score-driven distribution with a uniform baseline,
    so every shade keeps a chance even at the extremes (e.g. a few light leaves at
    score 100). variety=0 -> original behaviour; 0.15 -> ~10% lighter at max score.
    """
    s = score / 100.0
    deep = s ** 1.6
    pale = (1 - s) ** 1.6
    med = max(0.0, 1 - deep - pale)
    if variety > 0:
        u = 1.0 / 3.0
        deep = (1 - variety) * deep + variety * u
        med = (1 - variety) * med + variety * u
        pale = (1 - variety) * pale + variety * u
    r = np.random.default_rng(seed).random()
    return "deep" if r < deep else ("medium" if r < deep + med else "pale")


def cw_from_up(v):
    return math.degrees(math.atan2(v[0], -v[1]))


def _rot(v, deg):
    th = math.radians(deg)
    c, s = math.cos(th), math.sin(th)
    return np.array([c * v[0] - s * v[1], s * v[0] + c * v[1]])


def _unit(v):
    return v / (np.linalg.norm(v) + 1e-9)


# ======================================================================
#  Tree geometry + procedural anchor generation
# ======================================================================

class Tree:
    """Trunk-image geometry and the procedural leaf-anchor generator.

    Parameters (all tunable):
      twig_max   : px max branch *radius* that may bear leaves (excludes thick trunk)
      t_twig     : px thickness threshold for what counts as a thin twig (tips/skeleton sampling)
      splay      : deg an edge leaf tilts off the twig axis, toward its edge
      step       : px spacing of centreline samples along branches
      min_a      : px minimum spacing between final anchors (dedupe)
      tip_tan_r  : px neighbourhood radius for the tip direction
      mid_tan_r  : px neighbourhood radius for the mid-branch tangent
      grad_step  : px step used to read the geodesic gradient (orient the tangent)
    """

    def __init__(self, trunk_path,
                 twig_max=24.0, t_twig=12,
                 splay=30.0, step=40.0, min_a=28.0,
                 tip_tan_r=14.0, mid_tan_r=16.0, grad_step=7.0):
        self.trunk_path = trunk_path
        self.twig_max = twig_max
        self.t_twig = t_twig
        self.splay = splay
        self.step = step
        self.min_a = min_a
        self.tip_tan_r = tip_tan_r
        self.mid_tan_r = mid_tan_r
        self.grad_step = grad_step

        self.trunk = Image.open(trunk_path).convert("RGBA")
        self.W, self.H = self.trunk.size
        a = np.asarray(self.trunk).astype(np.int32)
        A, R, G, B = a[..., 3], a[..., 0], a[..., 1], a[..., 2]

        # brown wood mask (excludes the soft grey ground shadow)
        branch = (A > 100) & (R > B + 8) & (R >= G - 2)
        branch = remove_small_holes(branch, area_threshold=400)
        branch = remove_small_objects(branch, min_size=300)
        self.BRANCH = branch
        self.DT = ndimage.distance_transform_edt(branch)        # branch radius at each px
        self.SKEL = skeletonize(branch)                          # 1-px centrelines

        k = np.array([[1, 1, 1], [1, 0, 1], [1, 1, 1]])
        nb = ndimage.convolve(self.SKEL.astype(np.uint8), k, mode="constant")
        self.ENDPTS = self.SKEL & (nb == 1) & (self.DT <= t_twig)  # twig tips

        self.CX = self.W * 0.5
        self.BASE_PT = np.array([self.CX, self.H * 0.62])
        self.BASECUT = 0.82 * self.H

        ys, xs = np.where(self.SKEL & (self.DT <= t_twig))
        self.SKXY = np.column_stack([xs, ys]).astype(float)
        self.KD = cKDTree(self.SKXY)

        self._build_geodesic()

    # ---- geodesic distance from the root, along the whole skeleton ----
    def _build_geodesic(self):
        sk_yx = np.array(np.where(self.SKEL)).T
        geo = np.full(self.SKEL.shape, -1.0)
        root = sk_yx[int(np.argmax(sk_yx[:, 0]))]            # lowest skeleton pixel = trunk base
        ry, rx = int(root[0]), int(root[1])
        geo[ry, rx] = 0.0
        dq = deque([(ry, rx)])
        H, W = self.SKEL.shape
        while dq:
            y, x = dq.popleft()
            base = geo[y, x]
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < H and 0 <= nx < W and self.SKEL[ny, nx] and geo[ny, nx] < 0:
                        geo[ny, nx] = base + (1.41421 if (dy and dx) else 1.0)
                        dq.append((ny, nx))
        self.GEO = geo
        self._sk_yx = sk_yx
        self._geo_kd = cKDTree(np.column_stack([sk_yx[:, 1], sk_yx[:, 0]]).astype(float))

    def _geo_at(self, pt):
        _, i = self._geo_kd.query([float(pt[0]), float(pt[1])])
        yx = self._sk_yx[i]
        return self.GEO[yx[0], yx[1]]

    def zone_of(self, x, y):
        upper = y < self.H * 0.46
        left = x < self.CX
        if (not upper) and abs(x - self.CX) < 0.08 * self.W:
            return None                                       # skip bare central trunk, lower half
        return ("UL" if left else "UR") if upper else ("LL" if left else "LR")

    def _tangent(self, p, r):
        idx = self.KD.query_ball_point(p, r)
        if len(idx) < 4:
            _, i = self.KD.query(p, k=6)
            idx = np.atleast_1d(i)
        pts = self.SKXY[idx]
        c = pts.mean(0)
        _, _, vt = np.linalg.svd(pts - c)
        return _unit(vt[0])

    def _growth_dir(self, p, r):
        """Twig growth direction: local tangent oriented toward increasing geodesic
        distance (away from the root, following the branch even as it curves)."""
        t = self._tangent(p, r)
        g_fwd = self._geo_at(np.array([p[0], p[1]]) + t * self.grad_step)
        g_bwd = self._geo_at(np.array([p[0], p[1]]) - t * self.grad_step)
        if g_bwd > g_fwd:
            t = -t
        elif g_fwd == g_bwd:
            if np.dot(t, np.array([p[0], p[1]]) - self.BASE_PT) < 0:
                t = -t
        return _unit(t)

    def _tip_direction(self, p, r):
        idx = self.KD.query_ball_point(p, r)
        if len(idx) < 3:
            _, i = self.KD.query(p, k=6)
            idx = list(np.atleast_1d(i))
        interior = self.SKXY[idx].mean(0)
        d = np.array([float(p[0]), float(p[1])]) - interior
        if np.linalg.norm(d) < 1e-6:
            return self._growth_dir(p, r)
        return _unit(d)

    def gen_anchors(self):
        """Return anchors as dicts {x,y (normalized 0..1), rot, zone, tip}, in reveal order.

        Rule: TIP leaves point along the twig; EDGE leaves sit on the branch
        silhouette and point the twig growth direction +/- `splay` toward their edge.
        """
        anchors = []  # [x_px, y_px, rot, zone, tip]

        # 1) tips
        tips = np.column_stack(np.where(self.ENDPTS))[:, ::-1].astype(float)
        for p in tips:
            x, y = float(p[0]), float(p[1])
            if y > self.BASECUT:
                continue
            z = self.zone_of(x, y)
            if not z:
                continue
            t = self._tip_direction(p, self.tip_tan_r)
            anchors.append([x, y, round(cw_from_up(t), 1), z, 1])

        # 2) edges along branches
        ys, xs = np.where(self.SKEL)
        cl = np.column_stack([xs, ys]).astype(float)
        cl = cl[self.DT[ys, xs] <= self.twig_max]
        order = np.argsort(-(np.hypot(cl[:, 0] - self.BASE_PT[0], cl[:, 1] - self.BASE_PT[1])))
        chosen = np.empty((0, 2)); samples = []
        for i in order:
            p = cl[i]
            if len(chosen) == 0 or np.all(((chosen - p) ** 2).sum(1) > self.step * self.step):
                samples.append(p); chosen = np.vstack([chosen, p])

        for p in samples:
            x, y = float(p[0]), float(p[1])
            if y > self.BASECUT:
                continue
            rad = max(1.0, float(self.DT[int(np.clip(y, 0, self.H - 1)), int(np.clip(x, 0, self.W - 1))]))
            g = self._growth_dir(p, self.mid_tan_r)
            n = _unit(np.array([-g[1], g[0]]))
            for s in (+1.0, -1.0):
                o = s * n
                edge = p + o * rad
                ex, ey = float(edge[0]), float(edge[1])
                if ey > self.BASECUT:
                    continue
                z = self.zone_of(ex, ey)
                if not z:
                    continue
                sign = 1.0 if (g[0] * o[1] - g[1] * o[0]) >= 0 else -1.0
                d = _rot(g, sign * self.splay)
                anchors.append([ex, ey, round(cw_from_up(_unit(d)), 1), z, 0])

        # dedupe (tips kept preferentially — added first)
        final = []; ch = np.empty((0, 2))
        for aa in anchors:
            p = np.array([aa[0], aa[1]])
            if len(final) == 0 or np.all(((ch - p) ** 2).sum(1) > self.min_a * self.min_a):
                final.append(aa); ch = np.vstack([ch, p])

        # reveal order: spatially-uniform with mild outer-first bias
        rr = np.random.default_rng(18)
        dd = np.array([np.hypot(a[0] - self.BASE_PT[0], a[1] - self.BASE_PT[1]) for a in final])
        dn = (dd - dd.min()) / ((dd.max() - dd.min()) + 1e-9) if len(dd) else dd
        keys = [float(rr.random()) - 0.5 * dn[i] for i in range(len(final))]
        ordered = [a for _, a in sorted(zip(keys, final), key=lambda t: t[0])]
        return [{"x": round(a[0] / self.W, 5), "y": round(a[1] / self.H, 5),
                 "rot": a[2], "zone": a[3], "tip": int(a[4])} for a in ordered]

    # ---- debug renderers ----
    def draw_skeleton(self):
        """Debug image: branch mask (grey) + skeleton (green) + twig tips (red)."""
        img = Image.new("RGB", (self.W, self.H), IVORY)
        px = np.array(img)
        px[self.BRANCH] = (210, 200, 188)
        px[self.SKEL] = (40, 140, 70)
        img = Image.fromarray(px)
        d = ImageDraw.Draw(img)
        ys, xs = np.where(self.ENDPTS)
        for x, y in zip(xs, ys):
            d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=(208, 64, 52))
        return img

    def draw_arrows(self, anchors, L=52):
        """Debug image: trunk + green stem dot + red arrow per anchor (leaf direction)."""
        img = Image.new("RGB", (self.W, self.H), IVORY)
        img.paste(self.trunk, (0, 0), self.trunk)
        d = ImageDraw.Draw(img)
        for a in anchors:
            x, y, rot = a["x"] * self.W, a["y"] * self.H, a["rot"]
            th = math.radians(rot); dx, dy = math.sin(th), -math.cos(th)
            ex, ey = x + dx * L, y + dy * L
            d.line([x, y, ex, ey], fill=(208, 64, 52), width=3)
            for ang in (150, 210):
                ah = math.radians(rot + ang)
                d.line([ex, ey, ex + math.sin(ah) * 13, ey - math.cos(ah) * 13], fill=(208, 64, 52), width=3)
            d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=(46, 140, 70))
        return img

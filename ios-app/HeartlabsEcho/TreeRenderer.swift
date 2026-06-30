import Foundation
import SwiftUI
import UIKit

// MARK: - Deterministic PRNG

/// SplitMix64 — a tiny, fully deterministic PRNG. Seeded per leaf so tone /
/// variant / size are stable across redraws (no flicker) and identical on every
/// device. This replaces NumPy's PCG64 from the Python reference: it is NOT
/// bit-identical to NumPy, but it uses the SAME per-leaf seed formula and the
/// SAME tone thresholds, so the statistical mix and determinism match.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in [0, 1) using the top 53 bits (same technique as the reference).
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 1 / 2^53
    }
}

/// Probabilistic per-leaf tone. Higher score ⇒ higher chance of a greener leaf,
/// so every zone is a natural MIX. Ports `treelib.tone_for` exactly.
///
/// `variety` (0…1) blends the score-driven distribution with a uniform baseline,
/// so every shade keeps a chance even at the extremes (a few light leaves at
/// score 100). 0 = original behaviour; 0.15 ≈ 10% lighter leaves at max score.
func toneForScore(_ s: Double, _ r: Double, variety: Double) -> String {
    var deep = pow(s, 1.6)
    var pale = pow(1 - s, 1.6)
    var med = max(0.0, 1 - deep - pale)
    if variety > 0 {
        let u = 1.0 / 3.0
        deep = (1 - variety) * deep + variety * u
        med = (1 - variety) * med + variety * u
        pale = (1 - variety) * pale + variety * u
    }
    if r < deep { return "deep" }
    if r < deep + med { return "medium" }
    return "pale"
}

// MARK: - Sprite convention (hardcoded — no per-sprite data file)

/// The leaf sprites are pre-normalized art (see scripts/normalize_sprites.py):
/// every leaf is upright with its stem at the bottom-centre and the blade
/// pointing straight up. So placement needs no detection and no leaf_stems.json —
/// just these two constants plus each image's own width/height.
enum LeafConvention {
    static let stemX: CGFloat = 0.5   // stem sits at horizontal centre
    static let stemY: CGFloat = 1.0   // …and at the bottom edge
    // blade points straight up (0°) by construction.

    /// Tone variety (0…1): chance of lighter shades even at high scores. Keep in
    /// sync with the Python preview's --variety default. 0 = pure score-driven.
    static let toneVariety: Double = 0.15
}

/// A leaf sprite resolved for drawing.
struct LeafSprite {
    let image: Image
    let aspect: CGFloat   // width / height (the only per-sprite dimension we need)
}

// MARK: - Tree assets (loaded once)

/// Loads and caches the trunk, the baked anchors, and both leaf sprite sets.
/// Resolved lazily on first use and shared for the app's lifetime.
final class TreeAssets {
    static let shared = TreeAssets()

    private(set) var loaded = false
    private(set) var loadError: String?

    /// Virtual canvas space = trunk pixel space from anchors.json (e.g. 1792×2035).
    private(set) var trunkW: CGFloat = 1
    private(set) var trunkH: CGFloat = 1
    private(set) var trunk: Image?

    /// Anchors grouped by zone, preserving JSON array order (= reveal order).
    private(set) var anchorsByZone: [String: [AnchorFile.Anchor]] = [:]

    /// sprites[styleRawValue][tone] → [LeafSprite]
    private(set) var sprites: [String: [String: [LeafSprite]]] = [:]

    private let tones = ["deep", "medium", "pale"]

    private init() { load() }

    private func load() {
        guard
            let anchorsURL = Bundle.main.url(forResource: "anchors", withExtension: "json"),
            let anchorsData = try? Data(contentsOf: anchorsURL)
        else {
            loadError = "Tree data (anchors.json) not found in bundle."
            return
        }

        do {
            let anchorFile = try JSONDecoder().decode(AnchorFile.self, from: anchorsData)
            trunkW = CGFloat(anchorFile.trunk_w)
            trunkH = CGFloat(anchorFile.trunk_h)

            guard let trunkImage = UIImage(named: "trunk") else {
                loadError = "Trunk image asset 'trunk' not found."
                return
            }
            trunk = Image(uiImage: trunkImage)

            var grouped: [String: [AnchorFile.Anchor]] = [:]
            for a in anchorFile.anchors {
                grouped[a.zone, default: []].append(a)
            }
            anchorsByZone = grouped

            // Enumerate sprites by name — no per-sprite data file needed.
            var resolved: [String: [String: [LeafSprite]]] = [:]
            for style in [LeafStyle.round, .elongated] {
                var byTone: [String: [LeafSprite]] = [:]
                for tone in tones {
                    var arr: [LeafSprite] = []
                    for k in 1...style.variantsPerTone {
                        let name = "leaf_\(style.rawValue)_\(tone)_\(k)"
                        if let ui = UIImage(named: name), ui.size.height > 0 {
                            arr.append(LeafSprite(image: Image(uiImage: ui),
                                                  aspect: ui.size.width / ui.size.height))
                        }
                    }
                    byTone[tone] = arr
                }
                resolved[style.rawValue] = byTone
            }
            sprites = resolved
            loaded = true
        } catch {
            loadError = "Failed to parse anchors.json: \(error.localizedDescription)"
        }
    }
}

// MARK: - The tree canvas

/// Draws the trunk then, per zone, the first N anchors (N from score), each leaf
/// placed with its stem on the anchor and rotated to the anchor's angle, tinted
/// by the probabilistic model. A direct port of `treelib.render_leaves`.
struct LifeTreeCanvas: View {
    /// Zone raw value → 0…100.
    let scores: [String: Int]
    var style: LeafStyle = .current

    private let seedBase = 13

    var body: some View {
        let assets = TreeAssets.shared
        // Margins on all sides give the canopy headroom so outward leaves aren't
        // clipped by the Canvas bounds (matches the Python reference render_leaves).
        let marginX = assets.trunkW * 0.06
        let marginTop = assets.trunkH * 0.07
        let marginBottom = assets.trunkH * 0.04
        let virtualW = assets.trunkW + 2 * marginX
        let virtualH = assets.trunkH + marginTop + marginBottom

        Canvas { context, size in
            guard assets.loaded, let trunk = assets.trunk else { return }

            // Scale the whole virtual (trunk-pixel) space to fit the view width.
            let scale = size.width / virtualW
            context.scaleBy(x: scale, y: scale)

            // Trunk first.
            context.draw(trunk, in: CGRect(x: marginX, y: marginTop, width: assets.trunkW, height: assets.trunkH))

            guard let styleSprites = assets.sprites[style.rawValue] else { return }
            let leafHeight = assets.trunkH * style.leafHeightFraction

            for zone in TreeZone.allCases {
                guard let anchors = assets.anchorsByZone[zone.rawValue], !anchors.isEmpty else { continue }
                let score = max(0, min(100, scores[zone.rawValue] ?? 0))
                let s = Double(score) / 100.0
                // round-half-to-even, matching Python's round() in the reference.
                let n = Int((Double(anchors.count) * Double(score) / 100.0).rounded(.toNearestOrEven))
                guard n > 0 else { continue }
                let zi = zone.index

                for i in 0..<min(n, anchors.count) {
                    let anchor = anchors[i]

                    // Per-leaf deterministic draws (seed formula matches the reference).
                    let seed = UInt64(zi * 100_003 + i * 97 + seedBase)
                    var rng = SplitMix64(seed: seed)
                    let toneRoll = rng.nextDouble()
                    let tone = toneForScore(s, toneRoll, variety: LeafConvention.toneVariety)

                    guard let variants = styleSprites[tone], !variants.isEmpty else { continue }
                    let k = min(variants.count - 1, Int(rng.nextDouble() * Double(variants.count)))
                    let jitter = rng.nextDouble()
                    let sprite = variants[k]

                    let drawnH = leafHeight * (0.85 + 0.3 * jitter)
                    let drawnW = drawnH * sprite.aspect
                    let ax = CGFloat(anchor.x) * assets.trunkW + marginX
                    let ay = CGFloat(anchor.y) * assets.trunkH + marginTop

                    // Stem (bottom-centre of the normalized sprite) lands on the
                    // anchor; rotate to the anchor angle (blade is up by construction).
                    var layer = context
                    layer.translateBy(x: ax, y: ay)
                    layer.rotate(by: .degrees(anchor.rot))
                    layer.draw(
                        sprite.image,
                        in: CGRect(
                            x: -LeafConvention.stemX * drawnW,
                            y: -LeafConvention.stemY * drawnH,
                            width: drawnW,
                            height: drawnH
                        )
                    )
                }
            }
        }
        .aspectRatio(virtualW / virtualH, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

import Foundation
import SwiftUI

// MARK: - Tree Zones

/// The four quadrants of the tree. Each maps to one life category.
/// Raw values match the keys in `anchors.json` and the score dictionaries.
enum TreeZone: String, CaseIterable, Codable {
    case UL, UR, LL, LR

    /// Stable zone index used in the per-leaf RNG seed (matches `treelib.ZI`).
    var index: Int {
        switch self {
        case .UL: return 0
        case .UR: return 1
        case .LL: return 2
        case .LR: return 3
        }
    }
}

// MARK: - Leaf Style (the build flag)

/// Which leaf art set the renderer loads. Both sets ship in the asset catalog;
/// flip `current` to switch. Elongated is the approved default (closer to the
/// reference mockup); round is kept for comparison / local testing.
enum LeafStyle: String {
    case round
    case elongated

    /// The active leaf set. Change this single line to switch the whole app.
    static let current: LeafStyle = .elongated

    /// Leaf height as a fraction of trunk height (matches `treelib.render_leaves`).
    var leafHeightFraction: CGFloat {
        self == .elongated ? 0.058 : 0.045
    }

    /// Number of sprite variants per tone in the asset catalog
    /// (leaf_<style>_<tone>_1 … _N).
    var variantsPerTone: Int {
        self == .elongated ? 4 : 3
    }
}

// MARK: - Status Band

/// The qualitative band a 0–100 score falls into.
enum ScoreBand {
    case thriving       // 70–100
    case growing        // 30–69
    case needsAttention // 0–29

    static func of(_ score: Int) -> ScoreBand {
        if score >= 70 { return .thriving }
        if score >= 30 { return .growing }
        return .needsAttention
    }

    var label: String {
        switch self {
        case .thriving: return "Thriving"
        case .growing: return "Growing"
        case .needsAttention: return "Needs attention"
        }
    }

    var range: String {
        switch self {
        case .thriving: return "70 – 100"
        case .growing: return "30 – 69"
        case .needsAttention: return "0 – 29"
        }
    }

    /// Tint used for the percentage, status text, and progress fill.
    var color: Color {
        switch self {
        case .thriving: return Color(red: 0.357, green: 0.451, blue: 0.318)       // deep sage
        case .growing: return Color.sageGreen                                      // medium sage
        case .needsAttention: return Color(red: 0.706, green: 0.741, blue: 0.667)  // pale sage
        }
    }
}

// MARK: - Life Category (data-driven config)

/// One life category. Data-driven so labels/sub-items can change without touching
/// the renderer or scoring logic. `id` doubles as the JSON key the LLM returns.
struct LifeCategory: Identifiable {
    let id: String
    let zone: TreeZone
    let title: String
    let subtitle: String
    let subItems: [String]
    let systemIcon: String  // SF Symbol name

    /// The four v1 categories, in display order (mirrors the mockup quadrants).
    static let all: [LifeCategory] = [
        LifeCategory(
            id: "about_me",
            zone: .UL,
            title: "About Me",
            subtitle: "Self-growth & well-being",
            subItems: ["Health", "Mindfulness", "Hobbies", "Personal growth", "Rest & reflection"],
            systemIcon: "person.crop.circle"
        ),
        LifeCategory(
            id: "work_goals",
            zone: .UR,
            title: "Work & Goals",
            subtitle: "Career & purpose",
            subItems: ["Career", "Projects", "Finances", "Learning", "Goals"],
            systemIcon: "briefcase"
        ),
        LifeCategory(
            id: "family_relationships",
            zone: .LL,
            title: "Family & Relationships",
            subtitle: "Love & connections",
            subItems: ["Partner", "Children", "Family time", "Home", "Support"],
            systemIcon: "person.2"
        ),
        LifeCategory(
            id: "social_life",
            zone: .LR,
            title: "Social Life",
            subtitle: "Friends & experiences",
            subItems: ["Friends", "Fun & leisure", "Events", "Community", "Adventures"],
            systemIcon: "person.3"
        ),
    ]

    static func forZone(_ zone: TreeZone) -> LifeCategory {
        all.first { $0.zone == zone }!
    }
}

// MARK: - Tree Score (the cached result)

/// The computed scores for one evaluation, plus the metadata used to decide
/// whether a rebuild is needed (≤1 rebuild/day, and only when inputs change).
struct TreeScore: Codable, Equatable {
    /// Zone raw value ("UL"/"UR"/"LL"/"LR") → 0…100.
    var scores: [String: Int]
    /// The date key (yyyy-MM-dd) this score was computed on.
    var computedDate: String
    /// A signature of the input entries; a change means a new past entry exists.
    var inputSignature: String

    func score(_ zone: TreeZone) -> Int {
        max(0, min(100, scores[zone.rawValue] ?? 0))
    }

    func band(_ zone: TreeZone) -> ScoreBand {
        ScoreBand.of(score(zone))
    }

    /// An all-zero score — the genuine near-empty "growing" tree (no/low data).
    static func empty(computedDate: String, inputSignature: String) -> TreeScore {
        TreeScore(
            scores: Dictionary(uniqueKeysWithValues: TreeZone.allCases.map { ($0.rawValue, 0) }),
            computedDate: computedDate,
            inputSignature: inputSignature
        )
    }
}

// MARK: - Bundled JSON shapes

/// `anchors.json` — the 372 baked leaf-stem anchors (array order = reveal order).
struct AnchorFile: Decodable {
    let trunk_w: Double
    let trunk_h: Double
    let anchors: [Anchor]

    struct Anchor: Decodable {
        let x: Double      // normalized 0…1 of trunk width
        let y: Double      // normalized 0…1 of trunk height
        let rot: Double    // degrees clockwise from straight-up
        let zone: String
        let tip: Int
    }
}


import SwiftUI

// MARK: - Goal Growth Art

/// Maps a goal's progress onto one of six hand-painted growth illustrations
/// (`goal_growth_0` … `goal_growth_5` in the asset catalog): a seedling that
/// grows into a full tree as the goal advances. A completed goal always shows
/// the fully grown tree.
///
/// Kept here (rather than a standalone file) so no new Swift file needs
/// registering in `project.pbxproj`.
enum GoalGrowth {
    /// Number of growth illustrations available (stages 0…5).
    static let stageCount = 6

    /// The stage index (0…5) for a goal's current progress.
    static func stageIndex(for goal: Goal) -> Int {
        if goal.isComplete { return stageCount - 1 } // full tree at 100%
        switch goal.progressPercent {
        case ..<0.15: return 0   // seedling
        case ..<0.35: return 1   // sprout
        case ..<0.55: return 2   // sapling
        case ..<0.75: return 3   // young tree
        default:      return 4   // nearly grown
        }
    }

    /// The asset-catalog image name for a goal's current progress.
    static func imageName(for goal: Goal) -> String {
        "goal_growth_\(stageIndex(for: goal))"
    }
}

// MARK: - Goal Card View

/// A single card displaying a goal's growth illustration alongside its title,
/// description, progress bar, and metrics. The illustration on the left grows
/// from a seedling to a full tree as the goal progresses.
struct GoalCardView: View {
    let goal: Goal

    private var progressRatio: String {
        "\(goal.currentProgress)/\(goal.targetProgress) \(goal.unit)"
    }

    private var percentText: String {
        "\(Int(goal.progressPercent * 100))%"
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            // Growth illustration — grows with progress. Each stage is
            // "zoomed" to fill nearly the full height of the card, so growth
            // reads through the plant's FORM (seedling → full tree) rather
            // than a change in size.
            Image(GoalGrowth.imageName(for: goal))
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            // Text + progress column
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                // Title row with right-aligned progress text
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.title)
                        .font(.echoCardTitle)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: Theme.Spacing.s)

                    Text(progressRatio)
                        .font(.echoSubheadline)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                // Description (truncated)
                if !goal.desc.isEmpty {
                    Text(goal.desc)
                        .font(.echoCaption)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // Progress bar + percentage
                HStack(spacing: Theme.Spacing.s) {
                    GoalProgressBar(progress: goal.progressPercent)
                    Text(percentText)
                        .font(.echoMicroLabel)
                        .foregroundColor(.textSecondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .echoCard()
    }
}

// MARK: - Progress Bar

/// A simple capsule-shaped progress bar for goals.
struct GoalProgressBar: View {
    let progress: Double // 0.0 – 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.softTaupe.opacity(0.4))
                Capsule()
                    .fill(Color.sageGreen)
                    .frame(width: max(0, geo.size.width * CGFloat(progress)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: Theme.Spacing.m) {
            GoalCardView(goal: Goal(
                title: "Morning Run Streak",
                description: "Go for a run every morning this month to build a consistent habit.",
                currentProgress: 7,
                targetProgress: 10,
                unit: "runs"
            ))
            GoalCardView(goal: Goal(
                title: "Read Every Evening",
                description: "Wind down with a few pages before bed.",
                currentProgress: 8,
                targetProgress: 21,
                unit: "days"
            ))
            GoalCardView(goal: Goal(
                title: "Learn German",
                description: "Daily practice toward conversational fluency.",
                currentProgress: 3,
                targetProgress: 100,
                unit: "lessons"
            ))
            GoalCardView(goal: Goal(
                title: "Save for a Trip",
                description: "Set aside a little each week.",
                currentProgress: 5000,
                targetProgress: 5000,
                unit: "EUR"
            ))
        }
        .padding()
    }
    .background(Color.warmIvory)
}

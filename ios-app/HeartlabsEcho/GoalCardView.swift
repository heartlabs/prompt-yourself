import SwiftUI

// MARK: - Goal Card View

/// A single card displaying a goal's title, description, progress bar, and metrics.
struct GoalCardView: View {
    let goal: Goal

    private var progressRatio: String {
        "\(goal.currentProgress)/\(goal.targetProgress) \(goal.unit)"
    }

    private var percentText: String {
        "\(Int(goal.progressPercent * 100))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // Title row with right-aligned progress text
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title)
                    .font(.echoCardTitle)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(progressRatio)
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
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
    let goal = Goal(
        title: "Morning Run Streak",
        description: "Go for a run every morning this month to build a consistent habit.",
        currentProgress: 7,
        targetProgress: 10,
        unit: "runs"
    )
    GoalCardView(goal: goal)
        .padding()
        .background(Color.warmIvory)
        .previewLayout(.sizeThatFits)
}

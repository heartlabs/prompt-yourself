import SwiftUI

// MARK: - Goal Card View

/// A single card displaying a goal's title, description, progress bar, and metrics.
struct GoalCardView: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row with right-aligned progress text
            HStack(alignment: .top) {
                Text(goal.title)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .foregroundColor(.taupeText)
                    .lineLimit(1)

                Spacer()

                Text("\(goal.currentProgress)/\(goal.targetProgress) \(goal.unit)")
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundColor(.taupeText.opacity(0.6))
                    .lineLimit(1)
            }

            // Description (truncated)
            if !goal.desc.isEmpty {
                Text(goal.desc)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            // Progress bar + percentage
            HStack(spacing: 8) {
                GoalProgressBar(progress: goal.progressPercent)
                Text("\(Int(goal.progressPercent * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundColor(.taupeText.opacity(0.55))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 4, y: 2)
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
                    .fill(Color.softTaupe.opacity(0.45))
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

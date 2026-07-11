import SwiftUI

// MARK: - Goal Detail Sheet

/// The expanded detail for a single goal, shown as a bottom sheet when a goal
/// card is tapped. Built on the shared `DetailView` container so it reads like
/// the Life-tree category sheet, but it fills the body with what a goal needs:
/// the full, untruncated description — no progress bar or status badge, which
/// belong to the tree's scoring model, not to a goal.
struct GoalDetailSheet: View {
    @ObservedObject private var loc = LocalizationService.shared
    let goal: Goal

    private var percent: Int { Int(goal.progressPercent * 100) }
    private var subtitle: String {
        "\(goal.currentProgress)/\(goal.targetProgress) \(goal.unit) · \(percent)%"
    }

    var body: some View {
        DetailView(title: goal.title, subtitle: subtitle) {
            // The growth illustration as the leading badge (same circular chip
            // and size as the category icon).
            ZStack {
                Circle()
                    .fill(Color.softTaupe.opacity(0.4))
                    .frame(width: 44, height: 44)
                Image(GoalGrowth.imageName(for: goal))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
            }
            .accessibilityHidden(true)
        } content: {
            if !goal.desc.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(loc.localized("about_this_goal"))
                        .font(.echoGroupLabel)
                        .foregroundColor(.textTertiary)
                    Text(goal.desc)
                        .font(.echoBody)
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Selected Goal (sheet routing)

/// Wraps the tapped goal so it can drive a `.sheet(item:)`, mirroring
/// `TreeView`'s `SelectedCategory`.
struct SelectedGoal: Identifiable {
    let goal: Goal
    var id: UUID { goal.id }
}

// MARK: - Preview

#Preview {
    Color.warmIvory
        .sheet(isPresented: .constant(true)) {
            GoalDetailSheet(goal: Goal(
                title: "Read Every Evening Before Bed",
                description: "Wind down with a few pages each night instead of scrolling. Success is a calmer mind and finishing a book a month — even a couple of pages counts as showing up.",
                currentProgress: 8,
                targetProgress: 21,
                unit: "days"
            ))
            .presentationDetents([.height(320), .large])
            .presentationDragIndicator(.visible)
        }
}

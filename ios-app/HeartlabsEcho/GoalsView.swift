import SwiftData
import SwiftUI

// MARK: - Goals View

/// Displays all goals in two groups: Active (open) and Completed.
/// Cards are ordered by most recently updated first.
struct GoalsView: View {
    @Query(sort: [SortDescriptor(\Goal.lastUpdatedAt, order: .reverse)])
    var allGoals: [Goal]

    private var openGoals: [Goal] {
        allGoals.filter { !$0.isComplete }
    }

    private var completedGoals: [Goal] {
        allGoals.filter { $0.isComplete }
    }

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            ScrollView {
                if allGoals.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ScreenTitle(text: "Goals")
                .padding(.top, Theme.Spacing.s)

            // Active goals group
            if !openGoals.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Active")
                    LazyVStack(spacing: Theme.Spacing.m) {
                        ForEach(openGoals, id: \.id) { goal in
                            GoalCardView(goal: goal)
                        }
                    }
                }
            }

            // Completed goals group
            if !completedGoals.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Completed")
                    LazyVStack(spacing: Theme.Spacing.m) {
                        ForEach(completedGoals, id: \.id) { goal in
                            GoalCardView(goal: goal)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ScreenTitle(text: "Goals")
                .padding(.top, Theme.Spacing.s)

            VStack(spacing: Theme.Spacing.l) {
                Image(systemName: "target")
                    .font(.system(size: 44))
                    .foregroundColor(.sageGreen.opacity(0.4))

                Text("No goals yet")
                    .font(.echoSectionTitle)
                    .foregroundColor(.textPrimary)

                Text("Tap the mic and ask Echo to help you set one.")
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

// MARK: - Preview

#Preview {
    GoalsView()
        .modelContainer(for: Goal.self, inMemory: true)
}

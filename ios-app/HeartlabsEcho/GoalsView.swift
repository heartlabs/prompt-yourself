import SwiftData
import SwiftUI

// MARK: - Goals View

/// Displays all goals in two sections: Active (open) and Completed.
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
        NavigationStack {
            ScrollView {
                if allGoals.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(Color.warmIvory)
            .navigationTitle("Goals")
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Active goals section
            if !openGoals.isEmpty {
                LazyVStack(spacing: 12) {
                    ForEach(openGoals, id: \.id) { goal in
                        GoalCardView(goal: goal)
                    }
                }
            }

            // Completed goals section
            if !completedGoals.isEmpty {
                Text("Completed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.taupeText.opacity(0.4))
                    .padding(.top, openGoals.isEmpty ? 0 : 8)

                LazyVStack(spacing: 12) {
                    ForEach(completedGoals, id: \.id) { goal in
                        GoalCardView(goal: goal)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundColor(.sageGreen.opacity(0.4))

            Text("No goals yet")
                .font(.title3.weight(.medium))
                .foregroundColor(.taupeText)

            Text("Tap the mic and ask Echo to help you set one.")
                .font(.subheadline)
                .foregroundColor(.taupeText.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

// MARK: - Preview

#Preview {
    GoalsView()
        .modelContainer(for: Goal.self, inMemory: true)
}

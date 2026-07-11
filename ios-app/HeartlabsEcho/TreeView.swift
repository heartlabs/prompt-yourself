import SwiftData
import SwiftUI

// MARK: - Your Life Screen

/// The "Your Life" tab: a growing tree visualizing four life categories. Each
/// category is pinned to its quadrant of the tree as a tappable chip (score,
/// status, progress); tapping one opens a detail sheet. A single reflection
/// card at the bottom names where to focus next.
struct TreeView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = TreeViewModel()

    /// The category whose detail sheet is open (nil = none).
    @State private var selected: SelectedCategory?

    #if DEBUG
    /// When on, the tree renders from `debugScores` instead of the computed
    /// state — lets you scrub scores in the simulator without seeding data.
    @State private var debugOverride = false
    @State private var showDebug = false
    @State private var debugScores: [String: Double] = ["UL": 72, "UR": 45, "LL": 20, "LR": 10]
    #endif

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.m)

                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.s)
            }
        }
        .preferredColorScheme(.light)
        .task {
            viewModel.setup(modelContext: modelContext)
            await viewModel.loadIfNeeded()
        }
        .sheet(item: $selected) { sel in
            CategoryDetailSheet(category: sel.category, score: sel.score)
                .presentationDetents([.height(430), .large])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .sheet(isPresented: $showDebug) { debugPanel }
        #endif
    }

    /// The main area, honoring a DEBUG score override when active.
    @ViewBuilder
    private var mainContent: some View {
        #if DEBUG
        if debugOverride {
            readyView(debugTreeScore)
        } else {
            stateContent
        }
        #else
        stateContent
        #endif
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .loading:
            loadingView
        case .error(let message):
            errorView(message)
        case .ready(let score):
            readyView(score)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your Life")
                    .font(.echoLargeTitle)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 6) {
                    Text(viewModel.monthLabel)
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundColor(.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textTertiary)
                }

                Text("Every reflection helps your tree grow.")
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            HStack(spacing: 14) {
                Button { Task { await viewModel.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)

                #if DEBUG
                Button { showDebug = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                #endif
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            ProgressView().tint(.sageGreen)
            Text("Growing your tree…")
                .font(.system(size: 15, design: .serif))
                .foregroundColor(.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "leaf")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.sageGreen.opacity(0.5))
            Text(message)
                .font(.echoBody)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
            Button { Task { await viewModel.refresh() } } label: {
                Text("Try again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, 11)
                    .background(Color.sageGreen)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.m)
    }

    // MARK: - Ready (the redesigned overview)

    private func readyView(_ score: TreeScore) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            treeWithChips(score)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FocusLineCard(text: viewModel.focusLine(for: score))
        }
    }

    /// The tree with a category chip anchored to each of its four quadrants.
    /// Because `LifeTreeCanvas` is aspect-fit, the overlays align to the tree's
    /// own edges — so the bottom chips sit at the tree's lower edge, filling the
    /// empty space beside the trunk base rather than covering the branches.
    private func treeWithChips(_ score: TreeScore) -> some View {
        LifeTreeCanvas(scores: score.scores)
            .overlay(alignment: .topLeading) { categoryChip(.UL, score, trailing: false) }
            .overlay(alignment: .topTrailing) { categoryChip(.UR, score, trailing: true) }
            .overlay(alignment: .bottomLeading) { categoryChip(.LL, score, trailing: false) }
            .overlay(alignment: .bottomTrailing) { categoryChip(.LR, score, trailing: true) }
    }

    /// A compact, tappable category chip: name, %, status, and a mini progress bar.
    private func categoryChip(_ zone: TreeZone, _ score: TreeScore, trailing: Bool) -> some View {
        let cat = LifeCategory.forZone(zone)
        let value = score.score(zone)
        let band = score.band(zone)
        return Button {
            selected = SelectedCategory(category: cat, score: value)
        } label: {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
                Text(cat.title)
                    .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text("\(value)%")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(band.color)
                    Text(band.label)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.textSecondary)
                }

                ProgressBar(fraction: Double(value) / 100.0, color: band.color)
                    .frame(width: 92, height: 5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 134, alignment: trailing ? .trailing : .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.warmIvory.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(4)
        .offset(y: -10)  // lift both top and bottom chips up slightly off the branches
    }

    // MARK: - DEBUG score preview

    #if DEBUG
    private var debugTreeScore: TreeScore {
        TreeScore(
            scores: debugScores.mapValues { Int($0.rounded()) },
            computedDate: "preview",
            inputSignature: "preview"
        )
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $debugOverride) {
                Text("DEBUG · Preview scores")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.taupeText)
            }
            .tint(.sageGreen)

            ForEach(TreeZone.allCases, id: \.self) { zone in
                debugSlider(zone)
            }
            HStack(spacing: 10) {
                debugPresetButton("Budding", [4, 8, 2, 6])
                debugPresetButton("Mixed", [72, 45, 20, 10])
                debugPresetButton("Thriving", [92, 96, 88, 94])
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.warmIvory)
        .presentationDetents([.medium])
    }

    private func debugSlider(_ zone: TreeZone) -> some View {
        let binding = Binding<Double>(
            get: { debugScores[zone.rawValue] ?? 0 },
            set: { debugScores[zone.rawValue] = $0 }
        )
        return HStack(spacing: 10) {
            Text(LifeCategory.forZone(zone).title)
                .font(.system(size: 12))
                .foregroundColor(.taupeText.opacity(0.8))
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            Slider(value: binding, in: 0...100, step: 1).tint(.sageGreen)
            Text("\(Int(binding.wrappedValue))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.taupeText)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func debugPresetButton(_ title: String, _ values: [Double]) -> some View {
        Button {
            let keys = TreeZone.allCases.map { $0.rawValue }
            for (key, value) in zip(keys, values) { debugScores[key] = value }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.taupeText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.6))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    #endif
}

// MARK: - Selected Category (sheet routing)

/// Snapshot of the tapped category + its score, driving the detail sheet.
private struct SelectedCategory: Identifiable {
    let category: LifeCategory
    let score: Int
    var id: String { category.id }
}

// MARK: - Category Detail Sheet

/// The expanded detail for one category: score, status, progress, and sub-items.
/// Deliberately holds no cross-category "focus" advice — that lives in the
/// single reflection card on the overview.
struct CategoryDetailSheet: View {
    let category: LifeCategory
    let score: Int

    private var band: ScoreBand { ScoreBand.of(score) }
    private let chipColumns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            // Title row
            HStack(spacing: Theme.Spacing.m) {
                ZStack {
                    Circle().fill(Color.softTaupe.opacity(0.4)).frame(width: 44, height: 44)
                    Image(systemName: category.systemIcon)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundColor(.taupeText)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.echoTitle)
                        .foregroundColor(.textPrimary)
                    Text(category.subtitle)
                        .font(.echoCaption)
                        .foregroundColor(.textSecondary)
                }
            }

            // Score + status
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Text("\(score)%")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .foregroundColor(band.color)
                Text(band.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(band.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(band.color.opacity(0.16)))
            }

            ProgressBar(fraction: Double(score) / 100.0, color: band.color)
                .frame(height: 8)

            // Sub-items
            Text("What this branch holds")
                .font(.echoGroupLabel)
                .foregroundColor(.textTertiary)
                .padding(.top, Theme.Spacing.xs)

            LazyVGrid(columns: chipColumns, alignment: .leading, spacing: 8) {
                ForEach(category.subItems, id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "leaf")
                            .font(.system(size: 11))
                            .foregroundColor(.sageGreen.opacity(0.7))
                        Text(item)
                            .font(.echoCaption)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.softTaupe.opacity(0.22))
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warmIvory)
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.softTaupe.opacity(0.4))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}

// MARK: - Reflection Card

/// The single cross-category reflection: names where to focus next.
struct FocusLineCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ZStack {
                Circle().fill(Color.sageGreen.opacity(0.16)).frame(width: 38, height: 38)
                Image(systemName: "leaf.circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(.sageGreen)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Balance grows with awareness.")
                    .font(.echoCaption)
                    .foregroundColor(.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.sageGreenFaint)
        )
    }
}

#Preview {
    TreeView()
        .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
}

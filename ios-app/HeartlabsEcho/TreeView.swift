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
    @ObservedObject private var loc = LocalizationService.shared

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
                .presentationDetents([.height(360), .large])
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
                Text(loc.localized("your_life"))
                    .font(.echoLargeTitle)
                    .foregroundColor(.textPrimary)

                Text(loc.localized("tree_subtitle"))
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            #if DEBUG
            Button { showDebug = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            ProgressView().tint(.sageGreen)
            Text(loc.localized("growing_tree"))
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
                Text(loc.localized("try_again"))
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

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Language (STT + LLM)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.taupeText)

                Picker("Language", selection: Binding(
                    get: { LocalizationService.shared.currentLanguage },
                    set: { LocalizationService.shared.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
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
    @ObservedObject private var loc = LocalizationService.shared
    let category: LifeCategory
    let score: Int

    private var band: ScoreBand { ScoreBand.of(score) }

    var body: some View {
        DetailView(title: category.title, subtitle: category.subtitle) {
            ZStack {
                Circle().fill(Color.softTaupe.opacity(0.4)).frame(width: 44, height: 44)
                Image(systemName: category.systemIcon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(.taupeText)
            }
        } content: {
            // Score + status — the metric readout is the category's own, not
            // part of the shared container.
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
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(loc.localized("what_branch_holds"))
                    .font(.echoGroupLabel)
                    .foregroundColor(.textTertiary)

                FlowLayout(spacing: 8) {
                    ForEach(category.subItems, id: \.self) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "leaf")
                                .font(.system(size: 11))
                                .foregroundColor(.sageGreen.opacity(0.7))
                            Text(item)
                                .font(.echoCaption)
                                .foregroundColor(.textPrimary)
                                .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.softTaupe.opacity(0.22))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Flow Layout

/// A simple wrapping layout: lays children left-to-right, wrapping to the next
/// line when they don't fit. Each child keeps its natural width, so chip text
/// is never truncated.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        let width = (maxWidth == .infinity) ? x : maxWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
    @ObservedObject private var loc = LocalizationService.shared
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
                Text(loc.localized("balance_grows"))
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

import SwiftData
import SwiftUI

// MARK: - Your Life Screen

/// The "Your Life" tab: a growing tree visualizing four life categories, with
/// per-category panels, a balance legend, and an encouraging focus line.
struct TreeView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = TreeViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    #if DEBUG
    /// When on, the tree renders from `debugScores` instead of the computed
    /// state — lets you scrub scores in the simulator without seeding data.
    /// Compiled out of Release builds entirely.
    @State private var debugOverride = false
    @State private var debugScores: [String: Double] = ["UL": 72, "UR": 78, "LL": 68, "LR": 80]
    #endif

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    mainContent
                    #if DEBUG
                    debugPanel
                    #endif
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        .preferredColorScheme(.light)
        .task {
            viewModel.setup(modelContext: modelContext)
            await viewModel.loadIfNeeded()
        }
    }

    /// The main area: the live state, unless a DEBUG score override is active.
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

    // MARK: - DEBUG score preview

    #if DEBUG
    /// A TreeScore built from the live slider values.
    private var debugTreeScore: TreeScore {
        TreeScore(
            scores: debugScores.mapValues { Int($0.rounded()) },
            computedDate: "preview",
            inputSignature: "preview"
        )
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $debugOverride) {
                Text("DEBUG · Preview scores")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.taupeText)
            }
            .tint(.sageGreen)

            if debugOverride {
                ForEach(TreeZone.allCases, id: \.self) { zone in
                    debugSlider(zone)
                }
                HStack(spacing: 10) {
                    debugPresetButton("Budding", [4, 8, 2, 6])
                    debugPresetButton("Mixed", [72, 78, 68, 80])
                    debugPresetButton("Thriving", [92, 96, 88, 94])
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.softTaupe.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.softTaupe.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func debugSlider(_ zone: TreeZone) -> some View {
        let binding = Binding<Double>(
            get: { debugScores[zone.rawValue] ?? 0 },
            set: { debugScores[zone.rawValue] = $0 }
        )
        return HStack(spacing: 10) {
            Text(LifeCategory.forZone(zone).title)
                .font(.system(size: 11, design: .default))
                .foregroundColor(.taupeText.opacity(0.8))
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            Slider(value: binding, in: 0...100, step: 1)
                .tint(.sageGreen)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.taupeText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.5))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Life")
                .font(.system(size: 36, weight: .medium, design: .serif))
                .foregroundColor(.taupeText)

            HStack(spacing: 6) {
                Text(viewModel.monthLabel)
                    .font(.system(size: 17, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.7))
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.taupeText.opacity(0.5))
            }

            Text("Every reflection helps your tree grow.")
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundColor(.taupeText.opacity(0.6))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.sageGreen)
            Text("Growing your tree…")
                .font(.system(size: 15, design: .serif))
                .foregroundColor(.taupeText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.sageGreen.opacity(0.5))
            Text(message)
                .font(.system(size: 16, design: .default))
                .foregroundColor(.taupeText.opacity(0.8))
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("Try again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 11)
                    .background(Color.sageGreen)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 12)
    }

    private func readyView(_ score: TreeScore) -> some View {
        VStack(spacing: 28) {
            // The tree.
            LifeTreeCanvas(scores: score.scores)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

            // Four category panels (UL, UR / LL, LR — mirrors the quadrants).
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(LifeCategory.all) { category in
                    CategoryPanel(category: category, score: score.score(category.zone))
                }
            }

            BalanceLegend()

            FocusLineCard(text: viewModel.focusLine(for: score))
        }
    }
}

// MARK: - Category Panel

/// One category card: icon, title, subtitle, sub-items, %, status, progress bar.
struct CategoryPanel: View {
    let category: LifeCategory
    let score: Int

    private var band: ScoreBand { ScoreBand.of(score) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.softTaupe.opacity(0.45))
                        .frame(width: 38, height: 38)
                    Image(systemName: category.systemIcon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.taupeText)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundColor(.taupeText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(category.subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.taupeText.opacity(0.55))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(category.subItems, id: \.self) { item in
                    HStack(spacing: 5) {
                        Image(systemName: "leaf")
                            .font(.system(size: 9))
                            .foregroundColor(.sageGreen.opacity(0.55))
                        Text(item)
                            .font(.system(size: 12))
                            .foregroundColor(.taupeText.opacity(0.75))
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(score)%")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                    .foregroundColor(band.color)
                Text(band.label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(band.color.opacity(0.85))
                ProgressBar(fraction: Double(score) / 100.0, color: band.color)
                    .frame(height: 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softTaupe.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.softTaupe.opacity(0.45))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}

// MARK: - Balance Legend

/// "Monthly balance overview" — the three status bands.
struct BalanceLegend: View {
    private let items: [ScoreBand] = [.thriving, .growing, .needsAttention]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly balance overview")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundColor(.taupeText)

            HStack(alignment: .top, spacing: 14) {
                ForEach(items, id: \.label) { band in
                    HStack(spacing: 7) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 14))
                            .foregroundColor(band.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(band.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.taupeText)
                            Text(band.range)
                                .font(.system(size: 11))
                                .foregroundColor(.taupeText.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softTaupe.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Focus Line

/// The encouraging closing line, derived from the lowest-scoring categories.
struct FocusLineCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.softTaupe.opacity(0.4))
                    .frame(width: 40, height: 40)
                Image(systemName: "leaf.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.sageGreen)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(.taupeText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Balance grows with awareness.")
                    .font(.system(size: 13))
                    .foregroundColor(.taupeText.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.sageGreenFaint)
        )
    }
}

#Preview {
    TreeView()
        .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
}

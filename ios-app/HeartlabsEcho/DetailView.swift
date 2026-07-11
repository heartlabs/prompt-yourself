import SwiftUI

// MARK: - Detail View (shared container)

/// A reusable "details about a thing" container, meant to be presented as a
/// bottom sheet: it slides up from the bottom and is dismissed with a
/// swipe-down or a tap outside (both come for free from `.sheet`).
///
/// It owns only the shared chrome — a leading icon with a title and subtitle —
/// and hands the rest of the space to the caller via `content`, so each screen
/// renders whatever that particular thing needs (a metric readout and sub-items
/// for a life category, a description for a goal, …).
///
/// Present from a `.sheet`, pairing with `.presentationDetents` and
/// `.presentationDragIndicator(.visible)` at the call site.
struct DetailView<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    private let icon: Icon
    private let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            // Header: icon + title/subtitle (the one fixed part).
            HStack(spacing: Theme.Spacing.m) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.echoTitle)
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.echoCaption)
                        .foregroundColor(.textSecondary)
                }
            }

            // Everything else is the caller's to define.
            content

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warmIvory)
    }
}

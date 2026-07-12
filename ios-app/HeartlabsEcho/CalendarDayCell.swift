import SwiftUI

// MARK: - CalendarDayCell

/// A single day cell in the calendar grid.
///
/// Pure renderer: takes immutable values and draws them. Owns zero lifecycle
/// state — the `CalendarViewModel` is the single source of truth.
struct CalendarDayCell: View {
    let day: Int
    let isSelected: Bool
    let hasEntry: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Today outline (unselected) — subtle ring around the number
                if isToday && !isSelected {
                    Circle()
                        .stroke(Color.sageGreen.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                }

                // Selected circle background (takes precedence)
                if isSelected {
                    Circle()
                        .fill(Color.sageGreen)
                        .frame(width: 44, height: 44)
                }

                // Day number
                Text("\(day)")
                    .font(.system(size: 20, weight: isSelected || isToday ? .semibold : .regular, design: .default))
                    .foregroundColor(textColor)
            }
            .frame(height: 44)

            // Entry indicator — always occupies the same height so rows with and
            // without a leaf stay perfectly aligned.
            Group {
                if hasEntry {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.sageGreen.opacity(isSelected ? 1.0 : 0.55))
                } else {
                    Color.clear
                }
            }
            .frame(height: 12)
            .offset(y: -2)
        }
    }

    private var textColor: Color {
        if isSelected {
            return .white
        }
        if isToday {
            return .sageGreen
        }
        return .taupeText.opacity(0.7)
    }
}

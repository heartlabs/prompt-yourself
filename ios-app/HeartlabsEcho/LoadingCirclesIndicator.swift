import SwiftUI

// MARK: - LoadingCirclesIndicator

/// A compact pulsing-circles animation shown while a summary is being generated.
///
/// Self-contained animation component. The `@State activeIndex` is a local
/// presentation detail (the animation frame index), not lifecycle state.
struct LoadingCirclesIndicator: View {
    @State private var activeIndex = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3) { i in
                Circle()
                    .fill(Color.sageGreen)
                    .frame(width: 10, height: 10)
                    .opacity(activeIndex == i ? 1.0 : 0.25)
                    .scaleEffect(activeIndex == i ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 0.25), value: activeIndex)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

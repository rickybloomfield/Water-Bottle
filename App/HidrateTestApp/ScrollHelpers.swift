import SwiftUI

extension View {
    /// Reports how far the content has scrolled up, as 0…1 over the first few points, so
    /// a header above it can fade a shadow in as the content slides beneath rather than
    /// switching one on.
    func trackScrolledUnder(_ amount: Binding<CGFloat>, over distance: CGFloat = 14) -> some View {
        modifier(ScrolledUnderModifier(amount: amount, distance: distance))
    }
}

private struct ScrolledUnderModifier: ViewModifier {
    @Binding var amount: CGFloat
    var distance: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                amount = min(max(offset / distance, 0), 1)
            }
        } else {
            // Nothing to read the offset from before 18, so the shadow simply stays.
            content.onAppear { amount = 1 }
        }
    }
}

extension View {
    /// Reports whether a scroll is in progress, and calls `onSettled` once it stops.
    ///
    /// A scroll position updates the whole way through a drag. Anything that should act
    /// on where the scroll *ended* has to wait for this instead, or it acts on every
    /// value the drag passes over.
    func onScrollSettled(_ isScrolling: Binding<Bool>, perform onSettled: @escaping () -> Void) -> some View {
        modifier(ScrollSettledModifier(isScrolling: isScrolling, onSettled: onSettled))
    }
}

private struct ScrollSettledModifier: ViewModifier {
    @Binding var isScrolling: Bool
    var onSettled: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
                if phase == .idle { onSettled() }
            }
        } else {
            // No phase to watch before 18; `isScrolling` stays false and the caller acts
            // on each change, which is how this behaved before.
            content
        }
    }
}

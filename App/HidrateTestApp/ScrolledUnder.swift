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

import HidrateKit
import SwiftUI

/// What's in the bottle and whether we're still hearing from it, in one element. The old
/// screen split these — a level in the ring's shadow, a connection dot in a status line —
/// and neither half was much use without the other.
struct BottleStatusRow: View {
    @Environment(AppState.self) private var app

    /// The time of the most recent drink, which is the last thing the bottle told us.
    var lastDrink: Date?

    private var model: HidrateBottleModel { app.model }

    private var fill: Double? {
        if let demo = app.demoFillOverride { return demo }
        return model.displayFillFraction
    }

    /// "12.2 oz still in the bottle", or an honest shrug when it hasn't been calibrated.
    private var levelText: String {
        guard let level = model.displayLevelML else { return "Bottle level unknown" }
        return "\(app.volume(level)) still in the bottle"
    }

    private var statusText: String {
        var parts: [String] = []
        switch model.connectionState {
        case .connecting: parts.append("Finding bottle…")
        default: parts.append(model.isConnected ? "Connected" : "Not connected")
        }
        if let battery = model.batteryPercent { parts.append("\(battery)%") }
        if let lastDrink { parts.append(lastDrink.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private var dotColour: Color {
        if model.isConnected { return .green }
        if case .connecting = model.connectionState { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 14) {
            BottleGlyph(fill: fill)
                .frame(width: 24, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(levelText)
                    .font(.body.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(dotColour).frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // No chevron of its own: this row is the label of a NavigationLink, which
            // draws one, and two was one too many.
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small bottle whose fill is the level in the real one.
///
/// The same silhouette the hero bottle uses — shoulders, a neck the cap sits on, and a
/// shine down one side — rather than a rounded rectangle with a capsule floating above it.
/// What it does not do is simulate the water: at this size a straight waterline is all
/// that reads, so `BottleGeometry` is shared but the wave model is not.
struct BottleGlyph: View {
    var fill: Double?
    var tint: Color = .blue

    var body: some View {
        GeometryReader { proxy in
            let geo = BottleGeometry(size: proxy.size)
            let top = geo.neckTop
            let bottom = geo.body.maxY
            let level = bottom - (bottom - top) * min(max(fill ?? 0, 0), 1)

            ZStack {
                geo.cap.fill(tint.opacity(0.5))
                geo.silhouette.fill(tint.opacity(0.14))
                if fill != nil {
                    geo.silhouette
                        .fill(tint)
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: max(bottom - level, 0))
                        }
                }
                // Sits over both the water and the empty glass above it, as the glass
                // highlight on the hero bottle does.
                Path(roundedRect: CGRect(x: geo.body.minX + geo.w * 0.12,
                                         y: geo.body.minY + geo.h * 0.10,
                                         width: max(geo.w * 0.09, 1.5),
                                         height: geo.body.height * 0.5),
                     cornerRadius: geo.w * 0.05, style: .continuous)
                    .fill(.white.opacity(0.35))
            }
        }
        .accessibilityHidden(true)
    }
}

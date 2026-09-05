import SwiftUI

/// Four amounts and a way to reach the rest. Tapping one logs it there and then — the
/// sheet stops being the only way to record a glass you drank away from the bottle.
struct QuickAddRow: View {
    @Environment(AppState.self) private var app

    var onMore: () -> Void
    var onAdd: (Double) -> Void

    /// The four largest presets, biggest first — a bottle or a glass, rather than the
    /// sips at the small end of the list. The rest are a tap away behind the plus.
    private var presets: [Double] { Array(app.unit.presetsML.suffix(4).reversed()) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { ml in
                Button { onAdd(ml) } label: {
                    Text("+\(app.unit.number(ml))")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(background)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)
                .accessibilityLabel("Log \(app.volume(ml))")
            }
            Button(action: onMore) {
                // Composed into a text run rather than laid out as an image: a symbol's
                // own height is shorter than a line of text at the same size, which left
                // this chip 3pt shorter than the amounts beside it.
                Text(Image(systemName: "plus"))
                    .font(.body.weight(.semibold))
                    .frame(width: 52)
                    .padding(.vertical, 12)
                    .background(background)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.blue)
            .accessibilityLabel("Log a different amount")
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

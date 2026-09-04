import SwiftUI
import WatchKit

struct WatchTodayView: View {
    @Environment(WatchHydrationModel.self) private var model

    private var snapshot: HydrationSnapshot { model.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    HydrationRing(progress: snapshot.progress, overflow: snapshot.overflow,
                                  tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
                        HydrationRingLabel(snapshot: snapshot, numberSize: 26, goalSize: 11)
                    }
                    .frame(maxWidth: 104)
                    .animation(.spring(duration: 0.5), value: snapshot.totalML)

                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    presetGrid

                    Text("Hydration \(AppVersion.short)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
            }
            .navigationTitle("Hydration")
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
            ForEach(snapshot.presetsML, id: \.self) { ml in
                Button {
                    model.log(volumeML: ml)
                    WKInterfaceDevice.current().play(.click)
                } label: {
                    Text(snapshot.volume(ml))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue.opacity(0.35))
                .accessibilityLabel("Log \(snapshot.volume(ml))")
            }
        }
    }

    private var footer: String {
        model.pendingCount > 0 ? "\(model.pendingCount) waiting for iPhone" : snapshot.footer
    }
}

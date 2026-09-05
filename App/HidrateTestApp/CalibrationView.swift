import HidrateKit
import SwiftUI

/// Two readings — the bottle empty and the bottle full — are everything the app needs to
/// turn the scale into millilitres. This walks through taking them.
struct CalibrationView: View {
    @Environment(AppState.self) private var app
    @State private var emptyRaw: Double?
    @State private var fullRaw: Double?
    @State private var capturing: Step?
    @State private var failure: String?

    enum Step { case empty, full }

    private var model: HidrateBottleModel { app.model }

    private static let sizes = [21.0, 24.0, 32.0].map(BottleCalibration.capacityML(ounces:))

    /// The bottle's size, snapped to one of the offered ones. What the bottle says about
    /// itself is a round number of millilitres and the sizes are ounces converted, so
    /// the two never land on the same value and the picker would show nothing at all.
    private var capacity: Binding<Double> {
        Binding(
            get: {
                let current = app.capacityML
                return Self.sizes.min { abs($0 - current) < abs($1 - current) } ?? Self.sizes[0]
            },
            set: { app.capacityML = $0 }
        )
    }

    /// What the two captures in hand add up to, once there are two.
    private var candidate: BottleCalibration? {
        guard let emptyRaw, let fullRaw else { return nil }
        return BottleCalibration(emptyRaw: emptyRaw, fullRaw: fullRaw, capacityML: app.capacityML)
    }

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Text("Two readings teach the app what this bottle weighs empty and what it weighs full. It takes a couple of minutes, and holds until you change bottles.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Bottle holds", selection: capacity) {
                    ForEach(Self.sizes, id: \.self) { size in
                        Text(app.volume(size)).tag(size)
                    }
                }
            } footer: {
                Text("How much water goes in between the two readings. If you fill to below the brim, pick the amount you actually pour in.")
            }

            step(
                .empty,
                number: 1,
                title: "Empty the bottle",
                detail: "Empty it, dry it, lid on, standing on a level surface."
            )

            step(
                .full,
                number: 2,
                title: "Fill it up",
                detail: "Fill it to the top, lid on, same surface."
            )

            resultSection

            if model.calibration != nil {
                Section {
                    Button("Remove Calibration", role: .destructive) {
                        app.clearCalibration()
                        emptyRaw = nil
                        fullRaw = nil
                    }
                } footer: {
                    Text("Without a calibration the app can't read the water level or log what you drink from the bottle.")
                }
            }
        }
        .navigationTitle("Calibrate")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Calibration", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - A step

    @ViewBuilder
    private func step(_ step: Step, number: Int, title: String, detail: String) -> some View {
        let captured = value(for: step) != nil
        Section {
            HStack(alignment: .top, spacing: 14) {
                badge(number: number, done: captured)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if capturing == step {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the scale. Keep it still — this takes about a minute.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if captured {
                Button("Take It Again") { capture(step) }
                    .disabled(!model.isConnected || capturing != nil)
            }
        }

        // The button sits in its own section so the step above it stays a whole card
        // rather than one cut off at the bottom.
        if capturing != step, !captured {
            Section {
                Button {
                    capture(step)
                } label: {
                    Text("Take the Reading").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!model.isConnected || capturing != nil)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private func badge(number: Int, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.secondary.opacity(0.18))
                .frame(width: 28, height: 28)
            if done {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func value(for step: Step) -> Double? {
        step == .empty ? emptyRaw : fullRaw
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if !model.isConnected {
                Label("The bottle isn't connected. Readings come from its scale, so it has to be.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
            } else if let candidate {
                if !candidate.isValid {
                    Label("The full reading came out lower than the empty one. Take both again.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                } else if !candidate.looksReasonable {
                    Label("These two readings are further apart than a bottle can account for — one was probably taken while it was tilted or held. Take them again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Calibrated. The water level is ready to read.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if let existing = model.calibration, existing.isValid {
                Label("Calibrated \(existing.calibratedAt.formatted(date: .abbreviated, time: .shortened)).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Take both readings to finish.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Capturing

    private func capture(_ step: Step) {
        capturing = step
        Task {
            defer { capturing = nil }
            do {
                let raw = try await model.captureStableRaw(samples: 3, timeout: .seconds(120))
                app.sessionLog.write(String(format: "calibration capture %@ raw=%.1f", step == .empty ? "empty" : "full", raw))
                switch step {
                case .empty: emptyRaw = raw
                case .full: fullRaw = raw
                }
                // Saved the moment both readings exist and make sense; no extra tap.
                guard let candidate else { return }
                if candidate.isValid {
                    app.saveCalibration(emptyRaw: candidate.emptyRaw, fullRaw: candidate.fullRaw)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

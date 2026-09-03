import HidrateKit
import SwiftUI

struct CalibrationView: View {
    @Environment(AppState.self) private var app
    @State private var emptyRaw: Double?
    @State private var fullRaw: Double?
    @State private var capturing: Step?
    @State private var message: String?

    enum Step { case empty, full }

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                Section("Bottle size") {
                    Picker("Capacity", selection: $app.capacityML) {
                        Text("21 oz (621 mL)").tag(BottleCalibration.capacityML(ounces: 21))
                        Text("24 oz (710 mL)").tag(BottleCalibration.capacityML(ounces: 24))
                        Text("32 oz (946 mL)").tag(BottleCalibration.capacityML(ounces: 32))
                    }
                    Text("Capacity is the water volume between your empty and full captures. If you fill to below the brim, use the actual amount you poured in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Step 1 · Empty") {
                    Text("Empty and dry the bottle, put the lid on, and stand it on a flat surface. Then capture. The PRO 2 reports weight every 15 s, so each capture takes about a minute.")
                        .font(.footnote).foregroundStyle(.secondary)
                    captureRow(step: .empty, value: emptyRaw)
                }

                Section("Step 2 · Full") {
                    Text("Fill to the top (or to a known volume), lid on, same surface. Then capture.")
                        .font(.footnote).foregroundStyle(.secondary)
                    captureRow(step: .full, value: fullRaw)
                }

                Section("Result") {
                    if let emptyRaw, let fullRaw {
                        let candidate = BottleCalibration(emptyRaw: emptyRaw, fullRaw: fullRaw, capacityML: app.capacityML)
                        LabeledContent("Raw span", value: String(format: "%.0f units", candidate.rawSpan))
                        LabeledContent("Scale", value: String(format: "%.3f raw / mL", candidate.rawUnitsPerML))
                        if !candidate.isValid {
                            Label("Full must read higher than empty. Re-capture.", systemImage: "xmark.octagon").foregroundStyle(.red)
                        } else if !candidate.looksReasonable {
                            Label("Scale is far from the expected ~1.3 raw/mL. One capture was probably taken while the bottle was lifted.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Button("Save calibration") {
                            app.saveCalibration(emptyRaw: emptyRaw, fullRaw: fullRaw)
                            message = "Calibration saved."
                        }
                        .disabled(!candidate.isValid)
                    } else {
                        Text("Capture both steps to compute the calibration.").foregroundStyle(.secondary)
                    }
                }

                if let current = model.calibration {
                    Section("Current calibration") {
                        LabeledContent("Empty raw", value: String(format: "%.1f", current.emptyRaw))
                        LabeledContent("Full raw", value: String(format: "%.1f", current.fullRaw))
                        LabeledContent("Capacity", value: Format.ml(current.capacityML))
                        LabeledContent("Scale", value: String(format: "%.3f raw / mL", current.rawUnitsPerML))
                        LabeledContent("Calibrated", value: Format.dateTime.string(from: current.calibratedAt))
                        if let raw = model.stableRaw {
                            LabeledContent("Live reading", value: Format.mlAndOz(current.milliliters(forRaw: Double(raw))))
                        }
                        Button("Clear calibration", role: .destructive) { app.clearCalibration() }
                    }
                }

                Section("Live sensor") {
                    LabeledContent("Raw weight", value: model.latestWeight.map { String($0.raw) } ?? "—")
                    LabeledContent("Stable", value: model.stableRaw.map(String.init) ?? "—")
                    LabeledContent("Streak", value: "\(model.stableStreak)")
                }
            }
            .navigationTitle("Calibrate")
            .alert("Calibration", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    @ViewBuilder
    private func captureRow(step: Step, value: Double?) -> some View {
        HStack {
            if capturing == step {
                ProgressView()
                Text("Hold still… \(model.stableStreak) stable")
                    .foregroundStyle(.secondary)
            } else if let value {
                Text(String(format: "Captured raw %.1f", value))
            } else {
                Text("Not captured").foregroundStyle(.secondary)
            }
            Spacer()
            Button(step == .empty ? "Capture empty" : "Capture full") {
                capture(step)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isConnected || capturing != nil)
        }
    }

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
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

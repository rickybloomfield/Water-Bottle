import Foundation

/// The user's preferred volume unit. Storage is always millilitres; this converts and
/// formats at the edges.
///
/// Shared by the app, the widget and the watch app, so it deliberately depends on
/// nothing but Foundation.
enum VolumeUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case ounces
    case milliliters

    var id: String { rawValue }
    var title: String { self == .ounces ? "Ounces" : "Millilitres" }
    var symbol: String { self == .ounces ? "oz" : "mL" }

    /// Matches `BottleCalibration.millilitersPerUSFluidOunce`; duplicated so the widget
    /// and watch targets don't have to link HidrateKit.
    static let mlPerOunce = 29.5735

    func value(fromML ml: Double) -> Double { self == .ounces ? ml / Self.mlPerOunce : ml }
    func ml(fromValue value: Double) -> Double { self == .ounces ? value * Self.mlPerOunce : value }

    /// Sensible stepper increment for goals, expressed in mL.
    var goalStepML: Double { self == .ounces ? Self.mlPerOunce * 4 : 100 }
    /// Sensible increment for a manual drink, in mL.
    var drinkStepML: Double { self == .ounces ? Self.mlPerOunce * 0.5 : 10 }

    /// What a drink logged by hand starts at: a glass, in whichever unit you think in.
    var defaultDrinkML: Double { self == .ounces ? Self.mlPerOunce * 12 : 350 }

    /// One-tap amounts, offered in the app's log sheet and on the watch.
    var presetsML: [Double] {
        self == .ounces
            ? [4, 8, 12, 16.9, 21, 24].map { $0 * Self.mlPerOunce }
            : [100, 250, 350, 500, 621, 710]
    }


    /// "18 oz" / "532 mL". Ounces show one decimal only when small.
    func format(_ ml: Double, showUnit: Bool = true) -> String {
        let v = value(fromML: ml)
        let number: String
        switch self {
        case .milliliters: number = String(Int(v.rounded()))
        case .ounces:
            // Whole amounts read cleaner ("8 oz"); non-whole ones keep one decimal ("16.9 oz").
            let tenths = (v * 10).rounded() / 10
            number = tenths == tenths.rounded() ? String(Int(tenths.rounded())) : String(format: "%.1f", tenths)
        }
        return showUnit ? "\(number) \(symbol)" : number
    }

    /// Just the number, for big hero displays and the watch complication.
    func number(_ ml: Double) -> String { format(ml, showUnit: false) }
}

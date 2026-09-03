import HidrateKit
import SwiftUI

@main
struct HidrateTestApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem { Label("Bottle", systemImage: "waterbottle") }
                IntakeView()
                    .tabItem { Label("Intake", systemImage: "drop") }
                CalibrationView()
                    .tabItem { Label("Calibrate", systemImage: "scalemass") }
                ExploreView()
                    .tabItem { Label("Explore", systemImage: "antenna.radiowaves.left.and.right") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .environment(app)
        }
    }
}

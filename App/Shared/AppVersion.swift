import Foundation

/// The running build, shown on the phone and on the watch. The watch app and the widget
/// are installed separately from the app itself and can lag behind it, so being able to
/// read the version off each one is the only reliable way to tell what is actually there.
enum AppVersion {
    static var short: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

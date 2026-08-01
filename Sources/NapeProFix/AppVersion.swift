import Foundation

/// The version shown in the UI: `1.0.1`.
///
/// `CFBundleVersion` is still incremented on every build because macOS wants a
/// monotonic build counter, but it is not displayed — it made the version
/// string longer without telling the user anything they act on. It is still
/// visible in Finder's Get Info panel if a build ever needs pinning down.
enum AppVersion {
    static var display: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

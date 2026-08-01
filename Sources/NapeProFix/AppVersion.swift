import Foundation

/// The version, always shown down to the build number: `1.0.0.1`.
///
/// Reported as four parts so a rebuilt copy can be told apart from the one
/// already installed — the first three come from CFBundleShortVersionString,
/// the last from CFBundleVersion.
enum AppVersion {
    static var full: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short).\(build)"
    }
}

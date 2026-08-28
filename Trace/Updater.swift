import Sparkle
import SwiftUI

/// Auto-update, via Sparkle.
///
/// Trace is distributed outside the App Store, so nothing updates it on the
/// user's behalf unless the app does it itself. Sparkle is the standard answer:
/// it checks a signed appcast, and only installs a build whose EdDSA signature
/// matches the public key baked into this bundle — so a tampered or
/// man-in-the-middled download is refused even though the transport is plain
/// HTTPS from a static host.
///
/// The signing key lives in the developer's login Keychain, never in the repo.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    /// "1.2 (34)" — what the About row and the appcast comparison both use.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var lastCheckDescription: String {
        guard let lastCheck else { return "Not checked yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastCheck, relativeTo: Date()))."
    }
}

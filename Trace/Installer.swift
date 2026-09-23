import AppKit

/// Makes sure the running copy lives in an Applications folder, and moves it
/// there if not.
///
/// This exists because macOS remembers your default browser *by location*. A
/// copy anywhere else works right up until that location changes — the next
/// clean build, emptying Downloads, a Gatekeeper translocation path that is
/// different on every launch — and then web links silently stop reaching the
/// app. Sparkle also refuses to update a copy it can't replace in place. Rather
/// than documenting that as a manual step, the app relocates itself.
enum Installer {

    enum Location: String {
        /// /Applications or ~/Applications, or a folder inside either.
        case applications
        /// Xcode's build products, or a temporary folder a script built into.
        case buildFolder
        /// Gatekeeper's App Translocation: a quarantined app opened where it was
        /// downloaded is run from a random read-only path that changes on every
        /// launch, so nothing registered from here survives a relaunch.
        case translocated
        /// Anywhere else — typically Downloads or the Desktop.
        case elsewhere
    }

    static var location: Location {
        location(of: Bundle.main.bundleURL.standardizedFileURL.path)
    }

    /// The classification itself, apart from `Bundle.main` so it can be tested.
    static func location(
        of path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    ) -> Location {
        // Before the temporary-folder check: translocated apps also live under
        // /private/var/folders.
        if path.contains("/AppTranslocation/") { return .translocated }

        if path.contains("/DerivedData/")
            || path.contains("/Build/Products/")
            || path.contains("/Xcode/")
            // `mktemp -d`, where install.sh and release.sh build. release.sh
            // launches that copy for a smoke test; treating it as a stray copy
            // would put a modal alert in the way, and the launch repair would
            // unregister the installed app as a stale duplicate.
            || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/") {
            return .buildFolder
        }

        for folder in ["/Applications", home + "/Applications"]
        where path.hasPrefix(folder + "/") {
            return .applications
        }
        return .elsewhere
    }

    /// Anything but an Applications folder. Taking the default-browser slot, the
    /// launch-time registration repair and "set up" all wait on this.
    static var needsMove: Bool { location != .applications }

    /// Worth interrupting launch for: a copy someone downloaded and opened in
    /// place. A build folder already has a banner in Settings, and a developer
    /// running one wants no alert.
    static var shouldOfferMoveAtLaunch: Bool {
        location == .translocated || location == .elsewhere
    }

    /// Where this copy is, in words, for the banner and the launch alert.
    static var locationDescription: String {
        switch location {
        case .applications:
            return "the Applications folder"
        case .buildFolder:
            return "a build folder"
        case .translocated:
            return "a temporary location macOS assigned because it was opened where "
                 + "it was downloaded"
        case .elsewhere:
            let folder = Bundle.main.bundleURL.deletingLastPathComponent()
            return FileManager.default.displayName(atPath: folder.path)
        }
    }

    /// /Applications when it's writable (it is for admin users), otherwise
    /// ~/Applications, which never needs a password.
    static func destination() -> URL {
        let name = Bundle.main.bundleURL.lastPathComponent

        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent(name)
    }

    /// Copies this app to its permanent home, launches that copy, and quits this
    /// one. `completion` is only called if something went wrong — on success the
    /// process is on its way out.
    /// `completion` is main-actor-isolated because callers update UI state in it.
    static func installAndRelaunch(completion: @escaping @MainActor (String) -> Void) {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let target = destination()
        let from = location

        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        } catch {
            let message = "Couldn't copy to \(target.path): \(error.localizedDescription)"
            Task { @MainActor in completion(message) }
            return
        }

        // A copy made in code keeps the download's quarantine flag, and a
        // quarantined app that the user didn't move in Finder is translocated
        // again on launch — the copy in /Applications would run from a random
        // path just like this one. The user has already cleared this build
        // through Gatekeeper by opening it, so the flag has done its job.
        clearQuarantine(at: target)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            let path = target.path
            Task { @MainActor in
                if let error {
                    completion("Copied to \(path), but couldn't launch it: "
                               + error.localizedDescription)
                    return
                }
                // Leave no second copy behind to be opened by mistake. Only for
                // a plain stray copy: a build folder is Xcode's to manage, and a
                // translocated path is a read-only view whose real location
                // macOS doesn't disclose.
                if from == .elsewhere {
                    NSWorkspace.shared.recycle([source]) { _, _ in
                        Task { @MainActor in NSApp.terminate(nil) }
                    }
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func clearQuarantine(at bundle: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(bundle.path, attribute, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let relative as String in items {
            removexattr(bundle.appendingPathComponent(relative).path, attribute, XATTR_NOFOLLOW)
        }
    }
}

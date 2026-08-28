import AppKit

/// Moves the app out of Xcode's build folder so it has a permanent home.
///
/// This exists because macOS remembers your default browser *by location*. An app
/// left in DerivedData works fine right up until the next clean build, at which
/// point web links silently stop opening and the cause isn't obvious. Rather than
/// documenting that as a manual step, the app relocates itself.
enum Installer {

    static var isRunningFromBuildFolder: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/DerivedData/")
            || path.contains("/Build/Products/")
            || path.contains("/Xcode/")
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
            let message = "Couldn't copy to \(target.path) — \(error.localizedDescription)"
            Task { @MainActor in completion(message) }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            let path = target.path
            Task { @MainActor in
                if let error {
                    completion("Copied to \(path), but couldn't launch it — "
                               + error.localizedDescription)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

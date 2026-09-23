import AppKit
import CoreServices

/// Everything to do with being — or becoming — the system's web link handler.
///
/// This app holds the default-browser slot itself. There is no router in front
/// of it: macOS hands us every http/https URL, we keep the Dropbox share links
/// and pass the rest straight to the browser chosen in Settings.
///
/// The one thing that reliably breaks that is LaunchServices holding more than
/// one registration for this bundle id — Xcode leaves a copy in DerivedData
/// registered as an https handler every time you build, and a copy in an archive
/// build folder on top of that. When several registrations claim the same id,
/// macOS can route a click to a path that no longer exists, System Settings
/// stops offering the app in the Default web browser list, and the app looks
/// unstable for reasons nothing in its own code can explain. `repair()` is the
/// fix, and it is the only diagnostic worth keeping.
enum DefaultBrowser {

    static func systemDefaultURL() -> URL? {
        guard let probe = URL(string: "https://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static var isCurrent: Bool {
        guard let handler = systemDefaultURL() else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Does macOS count this app among the apps that can open https? If this is
    /// false the Default web browser list won't offer it, and `repair()` is the
    /// thing to try.
    static var isEligible: Bool {
        guard let probe = URL(string: "https://example.com") else { return false }
        let mine = Bundle.main.bundleURL.standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .contains { $0.standardizedFileURL.path == mine }
    }

    /// Which copy to hand macOS as the default browser.
    ///
    /// Never a copy outside an Applications folder: a build folder is gone on
    /// the next clean build, Downloads gets emptied, and a translocated path
    /// changes on every launch — macOS records the handler by location, so any
    /// of those breaks links later. If an installed copy exists, nominate it.
    static func targetForDefault() -> URL {
        if Installer.needsMove {
            let installed = Installer.destination()
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        return Bundle.main.bundleURL
    }

    /// Ask macOS to make this app the handler for web links.
    ///
    /// Two APIs, because the modern one is fussier than the job requires.
    /// `NSWorkspace.setDefaultApplication` shows the user a confirmation, which
    /// is the right way round, but it refuses outright for an app that isn't
    /// Developer ID-signed and notarised — with "the file couldn't be opened",
    /// which explains nothing. `LSSetDefaultHandlerForURLScheme` is deprecated
    /// and silent, but it does the job for a locally-signed app.
    ///
    /// Return codes from the older API are not to be trusted: setting `http`
    /// returns success and cascades to `https`, and the subsequent `https` call
    /// then reports -54 (permErr) for a binding it has *already* made. So we set
    /// all three, ignore what they claim, and check the end state instead.
    static func request(completion: @escaping @MainActor (String?) -> Void) {
        let me = targetForDefault()

        guard FileManager.default.fileExists(atPath: me.path) else {
            let message = "There's no app at \(me.path) to make the default. Use \"Move to "
                + "Applications and relaunch\" at the top of this window first."
            Task { @MainActor in completion(message) }
            return
        }

        if Installer.needsMove, me == Bundle.main.bundleURL {
            let message = "This copy is running from \(Installer.locationDescription). Move "
                + "it to the Applications folder first, then try again."
            Task { @MainActor in completion(message) }
            return
        }

        // Clear any stale sibling registration first. A second copy claiming the
        // same bundle id makes both routes fail.
        //
        // `repair()` shells out to lsregister, which takes tens of seconds. This
        // is called straight from a button, so doing it inline froze the whole
        // window — beachball included — before anything visible happened.
        Task {
            _ = await repairAsync()
            await MainActor.run { claim(me, completion: completion) }
        }
    }

    @MainActor
    private static func claim(_ me: URL, completion: @escaping @MainActor (String?) -> Void) {
        // macOS is markedly more willing to grant the binding to a request from
        // the frontmost app, and this one has no Dock icon.
        NSApp.activate(ignoringOtherApps: true)

        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { error in
            if error == nil {
                NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in
                    Task { @MainActor in
                        if await settles() {
                            completion(nil)
                        } else {
                            completion(await claimViaLaunchServices())
                        }
                    }
                }
                return
            }
            Task { @MainActor in completion(await claimViaLaunchServices()) }
        }
    }

    // MARK: - Off the main thread

    /// `repair()` and `status()` both run `lsregister -dump`, which takes about
    /// four and a half seconds on its own and closer to a minute for the whole
    /// repair. Blocking `Process` reads must not happen on the main thread (the
    /// UI freezes) or on Swift's cooperative pool (it has a fixed number of
    /// threads and one of them would be gone for the duration), so both get a
    /// GCD thread of their own.
    static func repairAsync() async -> String { await offMainThread { repair() } }

    static func statusAsync() async -> String { await offMainThread { status() } }

    /// Wait for the handler binding to actually read back as `expected`.
    ///
    /// LaunchServices does not commit a binding synchronously, and the answer
    /// `NSWorkspace` gives comes from a cache that lags it. Reading `isCurrent`
    /// on the line after setting it therefore reports failure for a binding that
    /// is about to be — and then stays — ours, which is how a working install
    /// ended up showing a refusal it had never actually been given. Poll instead,
    /// and only believe the result once it has had time to land.
    @MainActor
    private static func settles(_ expected: Bool = true, within seconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if isCurrent == expected { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return isCurrent == expected
    }

    private static func offMainThread<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// The fallback: claim http, https and HTML documents outright. Returns nil
    /// once we really are the handler, or an explanation if even this is refused.
    @MainActor
    private static func claimViaLaunchServices() async -> String? {
        guard let identifier = Bundle.main.bundleIdentifier as CFString? else {
            return "This app has no bundle identifier."
        }
        _ = LSSetDefaultHandlerForURLScheme("http" as CFString, identifier)
        _ = LSSetDefaultHandlerForURLScheme("https" as CFString, identifier)
        _ = LSSetDefaultRoleHandlerForContentType("public.html" as CFString, .viewer, identifier)

        return await settles() ? nil : await refusal()
    }

    /// What's left to say when both routes have been refused.
    ///
    /// The signing explanation below is true of a locally-signed development
    /// build and false of a notarised one, so it is worth the second and a half
    /// `spctl` costs to find out which this is rather than assert it. Told the
    /// wrong story, someone with a perfectly good build goes looking for a
    /// certificate problem that isn't there.
    @MainActor
    private static func refusal() async -> String {
        if !isEligible {
            return "macOS doesn't currently count this app as an https handler. Press "
                 + "\"Repair registration\" below and try again."
        }
        guard await offMainThread({ gatekeeperAccepts() }) else {
            return """
            macOS refused to hand over the default-browser slot, and this is the one \
            thing here that isn't a bug to be fixed.

            This copy is signed with an Apple Development certificate, which Gatekeeper \
            rejects for distribution — `spctl -a -t exec` says "rejected". Every app \
            macOS does offer as a browser is Developer ID-signed and notarised. That \
            also keeps it out of the System Settings list, so there's no point looking \
            for it there.

            Signing with a Developer ID certificate and notarising the app removes \
            this for good. It needs a paid Apple Developer Program membership.
            """
        }
        return """
        macOS refused to hand over the default-browser slot.

        This copy is Developer ID-signed and Gatekeeper accepts it, so the signature \
        is not the problem — which leaves a stale LaunchServices registration or macOS \
        declining silently. Press "Repair registration" below, then try again. If it \
        still refuses, set it by hand in System Settings → Desktop & Dock → Default \
        web browser.
        """
    }

    /// Does Gatekeeper accept this build for execution? True for a Developer
    /// ID-signed, notarised copy; false for an Apple Development-signed one.
    ///
    /// Blocking `Process` call — only ever from `offMainThread`.
    private static func gatekeeperAccepts() -> Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", path]).contains(": accepted")
    }

    /// Hand the default-browser slot to another app.
    ///
    /// The mirror image of `request()`, and just as necessary: without it the
    /// only way to stop using Trace is to know that the setting lives in
    /// System Settings → Desktop & Dock, which is exactly the knowledge someone
    /// giving up on the app doesn't have. Same two routes, same reason — the
    /// modern API is politer, the deprecated one always works.
    static func hand(to bundleID: String, completion: @escaping @MainActor (String?) -> Void) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            Task { @MainActor in completion("That browser is no longer installed.") }
            return
        }

        // Same settling delay as claiming the slot, for the same reason: the
        // release is not visible the instant the call returns.
        @Sendable @MainActor func viaLaunchServices() async -> String? {
            let identifier = bundleID as CFString
            _ = LSSetDefaultHandlerForURLScheme("http" as CFString, identifier)
            _ = LSSetDefaultHandlerForURLScheme("https" as CFString, identifier)
            _ = LSSetDefaultRoleHandlerForContentType("public.html" as CFString, .viewer, identifier)
            return await settles(false) ? nil : "macOS refused to release the default-browser slot."
        }

        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { error in
            if error == nil {
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                    Task { @MainActor in
                        if await settles(false) {
                            completion(nil)
                        } else {
                            completion(await viaLaunchServices())
                        }
                    }
                }
                return
            }
            Task { @MainActor in completion(await viaLaunchServices()) }
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Repair

    /// Leave exactly one registration for this bundle id — the copy in use.
    ///
    /// Unregisters every other claimant, including ones whose bundle is no longer
    /// on disk (an old DerivedData path). Those can't be found by asking
    /// LaunchServices which apps open https, because it won't list a bundle it
    /// can't read, so the registration dump is the only place they show up.
    @discardableResult
    static func repair() -> String {
        guard let identifier = Bundle.main.bundleIdentifier else { return "No bundle id." }
        let mine = Bundle.main.bundleURL.standardizedFileURL.path

        let stale = registeredPaths(forBundleID: identifier).filter { $0 != mine }
        for path in stale {
            _ = run(lsregister, ["-u", path])
        }
        _ = run(lsregister, ["-f", "-R", "-trusted", mine])

        guard !stale.isEmpty else {
            return isEligible
                ? "Nothing to repair — this is the only registered copy, and macOS lists it as "
                + "a valid web browser."
                : "Only one copy is registered, but macOS still doesn't list it as an https "
                + "handler. Re-registered it; if that doesn't help, the Info.plist may not be "
                + "reaching the build."
        }
        return "Removed \(stale.count) stale registration\(stale.count == 1 ? "" : "s"):\n"
             + stale.map { "  • \($0)" }.joined(separator: "\n")
             + "\n\nThis copy is now the only one claiming http and https."
    }

    // MARK: - Launch-time repair

    /// Is the post-launch `repair()` worth running?
    ///
    /// It used to run five seconds after *every* launch, and it is not cheap:
    /// `lsregister -dump` alone is ~26MB of text, measured at 4.8s of CPU on
    /// this Mac, and holding and splitting it took the process from ~7MB to a
    /// 79MB peak — a login item paying that on every login, to find nothing.
    /// Duplicate registrations appear when a *new copy* of the app lands (a
    /// build, an install, an update), so run it once per copy: when this
    /// bundle's path, build number or executable differ from the last repaired
    /// one, or when macOS has stopped listing the app as an https handler, which
    /// is the symptom the repair exists for and costs well under a millisecond
    /// to check.
    static var launchRepairDue: Bool {
        !isEligible || UserDefaults.standard.string(forKey: launchRepairKey) != bundleStamp
    }

    static func markLaunchRepairDone() {
        UserDefaults.standard.set(bundleStamp, forKey: launchRepairKey)
    }

    private static let launchRepairKey = "registrationRepairedFor"

    /// Changes whenever a different build of the app is running from here.
    private static var bundleStamp: String {
        let bundle = Bundle.main
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let modified = bundle.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(bundle.bundleURL.standardizedFileURL.path)|\(build)|\(Int(modified))"
    }

    /// Every path LaunchServices has registered under this bundle id.
    private static func registeredPaths(forBundleID identifier: String) -> [String] {
        let dump = run(lsregister, ["-dump"], includeErrors: false)
        var paths: [String] = []
        var pending: String?

        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("path:") {
                // "path:   /Applications/Foo.app (0x1125c)" — drop the trailing handle.
                var value = String(text.dropFirst("path:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let paren = value.range(of: " (0x", options: .backwards) {
                    value = String(value[value.startIndex..<paren.lowerBound])
                }
                pending = value
            } else if text.hasPrefix("identifier:"), text.contains(identifier) {
                if let path = pending, path.hasSuffix(".app"), !paths.contains(path) {
                    paths.append(path)
                }
                // Records without a path of their own must not inherit this one.
                pending = nil
            }
        }
        return paths
    }

    /// The whole routing picture in a few lines, for the diagnostics clipboard.
    static func status() -> String {
        let identifier = Bundle.main.bundleIdentifier ?? "?"
        let registrations = registeredPaths(forBundleID: identifier)
        let schemes = (Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        return """
        bundle id      : \(identifier)
        running from   : \(Bundle.main.bundleURL.path)
        declares       : \(schemes.isEmpty ? "NO url schemes — Info.plist didn't reach the build" : schemes.joined(separator: ", "))
        https handler  : \(systemDefaultURL()?.path ?? "none")
        is default     : \(isCurrent)
        macOS lists us : \(isEligible)
        registrations  : \(registrations.count)
        \(registrations.map { "  • \($0)" }.joined(separator: "\n"))
        """
    }

    private static var lsregister: String {
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"
    }

    /// Runs a tool directly, with arguments passed as an array.
    ///
    /// This used to build a `/bin/sh -c` string with each path wrapped in single
    /// quotes, which broke — and could run whatever followed — on any path
    /// containing a `'`, and the stale paths come straight out of the
    /// LaunchServices dump. No shell, no quoting.
    private static func run(
        _ executable: String,
        _ arguments: [String],
        includeErrors: Bool = true
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice

        guard (try? process.run()) != nil else { return "" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

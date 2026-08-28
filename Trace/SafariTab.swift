import AppKit
import CoreServices

/// Putting a link in Safari's current window instead of a new one.
///
/// Handing a URL to LaunchServices leaves the tab-or-window decision entirely to
/// the browser, and Safari's default answer is a new window: "Open pages in tabs
/// instead of windows" ships set to Automatically, which means a tab only when
/// the front window is full screen. Nothing in `NSWorkspace.OpenConfiguration`
/// influences that — the only way to ask for a tab is to ask Safari itself.
///
/// Safari-only on purpose. Scripting a browser costs the user an Automation
/// permission prompt, and every other browser here already does the right thing
/// unprompted: Chromium has no window-versus-tab setting to get wrong, and
/// Firefox's default is a tab. A prompt buys nothing there.
enum SafariTab {
    static let bundleID = "com.apple.Safari"

    /// Whether Trace may drive Safari, as macOS currently has it recorded.
    enum Permission {
        /// Allowed. Tabs work.
        case granted
        /// The user has never been asked. Asking is a blocking system prompt.
        case notAsked
        /// Explicitly refused. Only System Settings can undo this.
        case denied
        /// Safari didn't answer, or something else went wrong.
        case unknown

        var summary: String {
            switch self {
            case .granted:  return "granted"
            case .notAsked: return "not yet asked"
            case .denied:   return "denied"
            case .unknown:  return "unknown"
            }
        }
    }

    /// From AEDataModel.h. Spelled out rather than imported because these two
    /// are the whole reason for the permission check, and a missing symbol here
    /// would silently become "always fall back".
    private static let notPermitted: OSStatus = -1743
    private static let wouldRequireConsent: OSStatus = -1744

    /// False means "this didn't happen" — for any reason at all, including
    /// permission not granted, Safari not running, and Safari
    /// having no window to add a tab to. The caller then takes the LaunchServices
    /// route. Nothing here is allowed to be a hard failure: a link that opens in
    /// the wrong shape is a nuisance, a link that doesn't open is a bug.
    static func open(_ url: URL, bundleID id: String) -> Bool {
        guard id == bundleID else { return false }

        // No point asking a browser that isn't running to add a tab, and doing
        // so would launch it via Apple Events, which is slower than the ordinary
        // route and would drag a permission prompt along with it.
        guard !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .isEmpty
        else { return false }

        guard permission == .granted else { return false }

        return run(script(for: url))
    }

    /// What macOS has on file, without asking the user anything. Cheap enough to
    /// read when a settings pane is on screen; it is a local TCC lookup.
    static var permission: Permission {
        switch status(askUser: false) {
        case noErr:               return .granted
        case wouldRequireConsent: return .notAsked
        case notPermitted:        return .denied
        default:                  return .unknown
        }
    }

    /// Shows the system's Automation prompt.
    ///
    /// Blocks until the user answers it, so this must never run on the way to
    /// opening a link, and never on the main thread. It exists so the permission
    /// can be granted deliberately from Settings rather than being sprung on
    /// someone mid-click.
    static func requestPermission(then completion: @escaping @Sendable () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = status(askUser: true)
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// The Automation list in System Settings, for undoing a refusal — the one
    /// thing the app cannot do for the user.
    static func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security"
                  + "?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    /// `askUser: false` answers from what the user has already decided and
    /// returns immediately; `true` may show the system prompt and block until it
    /// is answered.
    private static func status(askUser: Bool) -> OSStatus {
        var target = AEAddressDesc()
        var identifier = Array(bundleID.utf8)
        guard AECreateDesc(
            typeApplicationBundleID,
            &identifier,
            identifier.count,
            &target
        ) == noErr else { return notPermitted }
        defer { AEDisposeDesc(&target) }

        return AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            askUser
        )
    }

    static func script(for url: URL) -> String {
        """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then error number -128
            set _target to front window
            set _new to make new tab at end of tabs of _target ¬
                with properties {URL:"\(escaped(url.absoluteString))"}
            set current tab of _target to _new
            activate
        end tell
        """
    }

    /// The URL is going into an AppleScript string literal, so the two
    /// characters that could end it early have to be escaped. Share links
    /// contain neither, but a URL is user input arriving from a click.
    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}

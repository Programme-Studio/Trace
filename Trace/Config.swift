import AppKit
import Foundation

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Everything non-secret lives in UserDefaults. The refresh token lives in the Keychain.
enum Config {
    private static let d = UserDefaults.standard

    /// The Dropbox app registration Trace ships with.
    ///
    /// This identifies the *app* to Dropbox — it goes out as `client_id` and
    /// nothing else. It is not a credential for any account: every user still
    /// signs in to their own Dropbox in their own browser, and the refresh token
    /// that comes back is stored under their own email in their own Keychain.
    ///
    /// It is also not a secret. The OAuth flow here is PKCE with no client
    /// secret, which is exactly the public-client case the spec covers, so there
    /// is nothing embedding it can leak. The practical limits are Dropbox's:
    /// an app in Development status is capped at 50 linked accounts until it is
    /// approved for Production, and every user shares the app's rate limits.
    static let bundledAppKey = "oq0p1u92wpkraqs"

    /// An app key the user supplied themselves. Overrides the bundled one, for
    /// anyone who would rather run against their own registration.
    static var customAppKey: String {
        get { d.string(forKey: "appKey") ?? "" }
        set { d.set(newValue, forKey: "appKey") }
    }

    /// Dropbox app key from https://www.dropbox.com/developers/apps (Settings tab).
    static var appKey: String {
        let custom = customAppKey.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? bundledAppKey : custom
    }

    /// Email of the authorised account; also the Keychain account name.
    static var accountLabel: String? {
        get { d.string(forKey: "accountLabel") }
        set { d.set(newValue, forKey: "accountLabel") }
    }

    /// Local folder the account's paths are relative to,
    /// e.g. /Users/you/Library/CloudStorage/Dropbox-Saentys
    static var localRoot: String? {
        get { d.string(forKey: "localRoot") }
        set { d.set(newValue, forKey: "localRoot") }
    }

    /// Team root namespace id. Set for team accounts, nil for personal ones.
    /// Sent as the Dropbox-API-Path-Root header so returned paths line up with `localRoot`.
    static var pathRoot: String? {
        get { d.string(forKey: "pathRoot") }
        set { d.set(newValue, forKey: "pathRoot") }
    }

    /// Bundle identifier of the browser that non-Dropbox URLs get handed to.
    ///
    /// Identified by bundle id rather than file path on purpose. Safari's real
    /// location is inside a cryptex — /System/Volumes/Preboot/Cryptexes/App/… —
    /// which doesn't match the path LaunchServices reports elsewhere, so any
    /// path-based comparison silently fails to match. Bundle ids are stable.
    static var fallbackBrowserID: String? {
        get { d.string(forKey: "fallbackBrowserID") }
        set { d.set(newValue, forKey: "fallbackBrowserID") }
    }

    /// Whatever the user's browser is *right now*, remembered before we take over
    /// as the default handler. That's a far better guess than picking a browser
    /// for them, and it can only be captured before the switch.
    static func captureCurrentBrowserIfUnset() {
        guard fallbackBrowserID == nil,
              let current = DefaultBrowser.systemDefaultURL(),
              let id = Bundle(url: current)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier
        else { return }
        fallbackBrowserID = id
    }

    /// Whether to try scraping the link's name and Spotlight-searching for it
    /// when the API can't resolve the link.
    ///
    /// Off by default. It is the only thing that resolves a link while Dropbox
    /// is unreachable, but it is a guess: the name comes off the share page and
    /// the match comes off Spotlight, so the file it reveals is a file with the
    /// right name rather than the file behind the link. A single exact match is
    /// the only case it acts on — anything ambiguous opens in the browser — but
    /// that is still a different guarantee from the rest of the app, so it is
    /// opt-in.
    static var nameSearchFallback: Bool {
        get { d.object(forKey: "nameSearchFallback") as? Bool ?? false }
        set { d.set(newValue, forKey: "nameSearchFallback") }
    }

    /// Whether a link handed back to Safari should join the current window as a
    /// tab instead of opening a window of its own.
    ///
    /// On by default: a link that failed to resolve is already a small
    /// disappointment, and a stray window is a second one. Off is here for the
    /// people who would rather Trace not hold Automation permission for Safari
    /// at all — turning it off is the only way to make that permission
    /// genuinely unused. Applies to Safari alone; see `SafariTab`.
    static var openInNewTab: Bool {
        get { d.object(forKey: "openInNewTab") as? Bool ?? true }
        set { d.set(newValue, forKey: "openInNewTab") }
    }

    /// What happens once a link has been resolved.
    ///
    /// Revealing is the app's whole premise, but "I clicked a link to a PDF and
    /// I want the PDF" is a perfectly reasonable thing to want, and there is
    /// nowhere else to ask for it.
    enum Reveal: String, CaseIterable, Identifiable {
        case reveal, open
        var id: Self { self }

        var title: String {
            switch self {
            case .reveal: return "Reveal in Finder"
            case .open:   return "Open the file"
            }
        }
    }

    static var revealBehaviour: Reveal {
        get { Reveal(rawValue: d.string(forKey: "revealBehaviour") ?? "") ?? .reveal }
        set { d.set(newValue.rawValue, forKey: "revealBehaviour") }
    }

    /// Keep the list of recently opened links. The list holds the URLs
    /// themselves, so anyone who would rather it didn't can say so.
    static var keepHistory: Bool {
        get { d.object(forKey: "keepHistory") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepHistory") }
    }

    /// How long to wait for Dropbox before giving up and handing the link to the
    /// browser. Clamped: below a couple of seconds a normal lookup would lose,
    /// and past thirty the click has visibly gone nowhere.
    static var lookupTimeout: Double {
        get {
            let stored = d.object(forKey: "lookupTimeout") as? Double ?? 5
            return min(max(stored, 2), 30)
        }
        set { d.set(min(max(newValue, 2), 30), forKey: "lookupTimeout") }
    }

    static var isConfigured: Bool {
        !appKey.isEmpty && accountLabel != nil && localRoot != nil
    }

    /// A custom key is deliberately left in place across a disconnect — it's a
    /// setting, not part of the connection.

    /// The account's folder on this Mac, re-detected if Dropbox has been moved,
    /// re-linked, or signed out and back in. Returns nil when it genuinely isn't
    /// there — which the caller should report rather than treating as a crash.
    static func currentLocalRoot() -> String? {
        let fm = FileManager.default
        if let root = localRoot, fm.fileExists(atPath: root) { return root }

        if let fresh = DropboxRoots.root(isTeam: pathRoot != nil),
           fm.fileExists(atPath: fresh) {
            localRoot = fresh
            return fresh
        }
        return nil
    }

    /// Is the connected account a member of a Dropbox team? Read from the `team`
    /// object on the account, which is present regardless of whether the team
    /// uses the team-space root model.
    static var isTeamMember: Bool {
        get { d.bool(forKey: "isTeamMember") }
        set { d.set(newValue, forKey: "isTeamMember") }
    }

    /// What `root_info[".tag"]` said — "team", "user", or "unknown". Diagnostic only.
    static var rootInfoTag: String {
        get { d.string(forKey: "rootInfoTag") ?? "unknown" }
        set { d.set(newValue, forKey: "rootInfoTag") }
    }

    /// How many of the account's top-level folders were found in `localRoot`.
    /// Zero means the folder match is unverified and probably wrong.
    static var rootMatchScore: Int {
        get { d.integer(forKey: "rootMatchScore") }
        set { d.set(newValue, forKey: "rootMatchScore") }
    }

    /// Connected to a personal Dropbox while a team Dropbox is also synced here?
    ///
    /// This is the quietest way the setup can go wrong. Authorising is done on
    /// Dropbox's website, where you may already be signed in to the wrong
    /// account — everything then succeeds, and only work links fail, much later.
    static var likelyWrongAccount: Bool {
        // A team member is never the wrong account, whatever root model the team
        // uses — and the folder match is verified separately.
        guard isConfigured, !isTeamMember, pathRoot == nil else { return false }
        return DropboxRoots.read().contains { $0.isTeam }
    }

    /// The local folder was picked without any of the account's folders actually
    /// being found in it — worth saying so rather than failing quietly.
    static var rootMatchUnverified: Bool {
        isConfigured && rootMatchScore == 0 && DropboxRoots.read().count > 1
    }

    /// Name of the team folder we can see but aren't connected to.
    static var unconnectedTeamName: String? {
        guard let root = DropboxRoots.read().first(where: { $0.isTeam })?.root else { return nil }
        return (root as NSString).lastPathComponent
    }

    static func disconnect() {
        if let label = accountLabel { Keychain.delete(account: label) }
        accountLabel = nil
        localRoot = nil
        pathRoot = nil
    }

    /// Back to a fresh install: disconnect, forget every preference, drop the
    /// resolved-path cache. Deliberately does NOT touch the default-browser
    /// binding or the login item — both are macOS state rather than ours, and
    /// silently handing the browser slot back would be a bigger surprise than
    /// anything this button is being pressed to fix. Both have their own control
    /// elsewhere in the window.
    static func resetAll() {
        disconnect()
        ResolvedCache.clear()
        if let domain = Bundle.main.bundleIdentifier {
            d.removePersistentDomain(forName: domain)
        }
        d.synchronize()
        // Re-capture the browser to fall back to, or the next non-Dropbox link
        // has nowhere to go but Safari.
        captureCurrentBrowserIfUnset()
    }
}

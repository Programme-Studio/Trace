import Foundation

/// Carries an existing install across the rename from Dropbox Opener to Unbox.
///
/// The bundle identifier changed with the name, and macOS keys two things on it
/// that this app cannot afford to lose: the UserDefaults domain, which holds the
/// app key, the connected account, the local root and every remembered path; and
/// the Keychain service, which holds the Dropbox refresh token. Without this a
/// working install would come back from the rename looking like a first run —
/// setup wizard, no account, nothing remembered — with a perfectly good refresh
/// token stranded under a service name nothing looks up any more.
///
/// Runs once, before anything reads `Config`.
enum Migration {
    /// What the app was called when these were written.
    private static let legacyBundleID = "uk.co.researchunit.dropboxopener"
    private static let doneKey = "migratedFromDropboxOpener"

    /// Everything `Config` and `ResolvedCache` own. Deliberately an explicit list
    /// rather than a copy of the whole domain — AppKit leaves its own state in
    /// there (window frames, last-open directories) and none of it should follow
    /// the app to a new identity.
    private static let keys = [
        "appKey",
        "accountLabel",
        "localRoot",
        "pathRoot",
        "fallbackBrowserID",
        "nameSearchFallback",
        "isTeamMember",
        "rootInfoTag",
        "rootMatchScore",
        "resolvedLinks",
    ]

    /// Record the migration as already done without performing it.
    ///
    /// `Config.resetAll()` clears the whole UserDefaults domain, which includes
    /// this flag — and the old Dropbox Opener domain and Keychain item are both
    /// still on disk. Without this the next launch would helpfully re-import the
    /// account, the local root and the refresh token the user just asked to be
    /// rid of.
    static func markComplete() {
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // The app isn't sandboxed, so the old domain is readable directly.
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }

        for key in keys {
            // Never overwrite something already set under the new identity.
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key)
            else { continue }
            defaults.set(value, forKey: key)
        }

        // `ResolvedCache` reads the old `[String: String]` shape as well as the
        // current one, so remembered paths come across as they are.

        guard let account = defaults.string(forKey: "accountLabel"),
              Keychain.get(account: account) == nil,
              let token = Keychain.get(account: account, service: legacyBundleID)
        else { return }
        Keychain.set(token, account: account)
    }
}

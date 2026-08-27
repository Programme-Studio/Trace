import Foundation

/// Reads ~/.dropbox/info.json, which the Dropbox desktop app maintains.
///
/// A team account has both `path` (your own member folder, e.g. .../Dropbox-Saentys/Peter Bruce)
/// and `root_path` (the folder containing every team folder *and* your member folder).
/// The Dropbox API's team root namespace corresponds to `root_path`, so that's what we want.
enum DropboxRoots {
    struct Account {
        let key: String          // "business" or "personal"
        let root: String         // root_path if present, else path
        let isTeam: Bool

        /// The member's own Dropbox folder — info.json's `path`. This is what
        /// API paths are relative to when no path-root header is sent.
        let memberRoot: String

        /// The folder containing the team folders *and* the member folder —
        /// info.json's `root_path`, absent on a personal account. API paths are
        /// relative to this only when the team root namespace is sent as the
        /// path root.
        let teamRoot: String?
    }

    private static let lock = NSLock()
    private static var cached: [Account] = []
    /// Modification date and size of the info.json the cache was built from.
    private static var cachedStamp: (Date, Int)?

    /// `read()` is called from SwiftUI view bodies, from `Config.likelyWrongAccount`
    /// and friends, and from the resolve path — so it used to re-open and
    /// re-parse info.json on every redraw. Stat the file instead and only
    /// re-parse when it has actually changed; Dropbox rewrites it about as often
    /// as you sign in and out.
    static func read() -> [Account] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dropbox/info.json")

        lock.lock()
        defer { lock.unlock() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = attributes.flatMap { attributes -> (Date, Int)? in
            guard let date = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int
            else { return nil }
            return (date, size)
        }

        if let stamp, let cachedStamp, stamp == cachedStamp { return cached }

        let accounts = parse(url)
        cached = accounts
        cachedStamp = stamp
        return accounts
    }

    private static func parse(_ url: URL) -> [Account] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let obj = parsed as? [String: Any]
        else { return [] }

        return obj.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            guard let root = (entry["root_path"] as? String) ?? (entry["path"] as? String)
            else { return nil }
            return Account(
                key: key,
                root: root,
                isTeam: (entry["is_team"] as? Bool) ?? (key == "business"),
                memberRoot: (entry["path"] as? String) ?? root,
                teamRoot: entry["root_path"] as? String
            )
        }
        .sorted { $0.key < $1.key }
    }

    /// Best guess at the local root for an account, given whether the API says it's a team.
    static func root(isTeam: Bool) -> String? {
        let accounts = read()
        if let match = accounts.first(where: { $0.isTeam == isTeam }) { return match.root }
        return accounts.first?.root
    }

    /// Work out which local Dropbox folder an account corresponds to by checking
    /// which one actually contains the folders Dropbox reports at its top level.
    ///
    /// Inferring this from `root_info[".tag"] == "team"` was wrong: plenty of
    /// Dropbox Business teams don't use the team-space model, so a perfectly
    /// correct business account reports `"user"` and got matched to the personal
    /// folder — which then contains none of its files. Comparing against what's
    /// on disk is a fact rather than an inference.
    static func bestMatch(topLevel: [String], fallbackIsTeam: Bool) -> (root: String, score: Int)? {
        let accounts = read()
        guard !accounts.isEmpty else { return nil }
        guard !topLevel.isEmpty else {
            return root(isTeam: fallbackIsTeam).map { ($0, 0) }
        }

        let wanted = Set(topLevel.map { $0.lowercased() })
        let fm = FileManager.default
        var best: (root: String, score: Int)?

        for account in accounts {
            guard let entries = try? fm.contentsOfDirectory(atPath: account.root) else { continue }
            let present = Set(entries.map { $0.lowercased() })
            let score = wanted.intersection(present).count
            if best == nil || score > best!.score {
                best = (account.root, score)
            }
        }

        if let best, best.score > 0 { return best }
        return root(isTeam: fallbackIsTeam).map { ($0, 0) }
    }
}

import Foundation

/// Remembers where each share link turned out to live.
///
/// Consulted *first*, before any network call, so clicking a link you've opened
/// before reveals the file with no round trip at all. Freshness is handled by
/// re-checking in the background rather than by making every click wait:
/// `lookup` refuses a path that has gone, and an entry that hasn't been verified
/// for a while asks the caller to confirm it after the reveal.
enum ResolvedCache {
    private static let key = "resolvedLinks"

    /// Entries kept. Small enough to stay cheap to read and write whole.
    private static let limit = 300

    /// How much of the cache to discard when it's full. Trimming the oldest
    /// quarter keeps the recently-used links; the previous code cleared the
    /// whole dictionary, so every 300th link silently threw away every fast
    /// path the app had learned.
    private static let trimFraction = 0.25

    /// How long a remembered path is trusted before the next click also kicks
    /// off a background re-check. Files move rarely; asking Dropbox on *every*
    /// click cost a token refresh and a round trip for nothing.
    private static let revalidateAfter: TimeInterval = 3600

    /// UserDefaults gives no atomic read-modify-write, and `remember` is called
    /// from both the click path and the background re-check.
    private static let lock = NSLock()

    struct Hit {
        let path: String
        /// The entry is old enough that it's worth confirming behind the reveal.
        let needsRevalidation: Bool
    }

    /// Share links carry volatile query junk (`dl=0`, `st=…`), so key on the
    /// stable part: the host and path.
    private static func cacheKey(_ url: URL) -> String {
        (url.host?.lowercased() ?? "") + url.path
    }

    static func lookup(_ url: URL) -> Hit? {
        lock.lock()
        let entry = load()[cacheKey(url)]
        lock.unlock()

        guard let entry else { return nil }
        // A remembered path is only useful if it's still there.
        guard FileManager.default.fileExists(atPath: entry.path) else { return nil }

        return Hit(
            path: entry.path,
            needsRevalidation: Date().timeIntervalSince1970 - entry.verifiedAt > revalidateAfter
        )
    }

    static func remember(_ url: URL, path: String) {
        lock.lock()
        defer { lock.unlock() }

        var map = load()
        map[cacheKey(url)] = Entry(path: path, verifiedAt: Date().timeIntervalSince1970)

        if map.count > limit {
            let drop = max(1, Int(Double(limit) * trimFraction))
            for key in map.sorted(by: { $0.value.verifiedAt < $1.value.verifiedAt })
                .prefix(map.count - limit + drop)
                .map(\.key) {
                map.removeValue(forKey: key)
            }
        }
        save(map)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return load().count
    }

    // MARK: - Storage

    private struct Entry {
        let path: String
        let verifiedAt: TimeInterval
    }

    /// Reads both the current shape and the original `[String: String]` one, so
    /// an existing install keeps its remembered paths across the upgrade.
    private static func load() -> [String: Entry] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }

        var out: [String: Entry] = [:]
        for (cacheKey, value) in raw {
            if let legacyPath = value as? String {
                // No timestamp on the old format — treat it as due a re-check.
                out[cacheKey] = Entry(path: legacyPath, verifiedAt: 0)
            } else if let fields = value as? [String: Any],
                      let path = fields["path"] as? String {
                out[cacheKey] = Entry(
                    path: path,
                    verifiedAt: (fields["verifiedAt"] as? TimeInterval) ?? 0
                )
            }
        }
        return out
    }

    private static func save(_ map: [String: Entry]) {
        let raw = map.mapValues { ["path": $0.path, "verifiedAt": $0.verifiedAt] as [String: Any] }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

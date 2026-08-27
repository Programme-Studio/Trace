import Foundation

struct ResolveFailure: Sendable {
    enum Kind: Sendable {
        case notSetUp
        case notSynced       // selective sync — expected, not a malfunction
        case dropboxRootMissing
        case offline
        case dropbox         // Dropbox said no
        case ambiguous       // filename fallback found several matches
        case other
    }

    /// One short line, fit for a notification or a menu row.
    let headline: String
    /// Everything we learned, for the Settings window and diagnostics.
    let detail: String
    var kind: Kind = .other
    /// Where Dropbox says the file is, when we got that far.
    var dropboxPath: String? = nil
    /// The deepest folder on this Mac that does exist, for a "reveal that" button.
    var nearestLocalFolder: String? = nil
    /// Phase timings, for "why was that slow?".
    var trace: String = ""

    var symbol: String {
        switch kind {
        case .notSynced, .dropboxRootMissing, .offline: return "⚠"
        default: return "✗"
        }
    }
}

enum ResolveOutcome: Sendable {
    case revealed(path: String, via: String, trace: String)
    case failed(ResolveFailure)
}

/// Where the time went, phase by phase.
///
/// A click that takes two seconds is almost always a count of sequential network
/// round trips, and "it felt slow" can't be acted on without knowing which ones.
/// The total was already recorded; this says what made it up.
struct ResolveTrace: Sendable {
    private var marks: [(String, Int)] = []
    private var last = Date()

    mutating func mark(_ label: String) {
        let now = Date()
        marks.append((label, Int(now.timeIntervalSince(last) * 1000)))
        last = now
    }

    /// Only phases worth naming — sub-millisecond local work is noise.
    var summary: String {
        marks
            .filter { $0.1 >= 1 }
            .map { "\($0.0) \($0.1)ms" }
            .joined(separator: " · ")
    }
}

enum LinkResolver {

    /// Nothing should hang on a click. If Dropbox is slow or unreachable we give
    /// up and let the browser have the link rather than leaving the user staring
    /// at a menu bar icon.
    ///
    /// Five seconds. This was eight, then three; three turned out to be too
    /// tight once there were numbers to look at. A typical cold lookup on this
    /// account is a single `get_shared_link_metadata` call at ~750ms, but one
    /// was measured at 2.4s — which under a three-second deadline was 0.6s away
    /// from being thrown at the browser despite being a perfectly good answer
    /// that was on its way.
    ///
    /// The trade is asymmetric. Giving up early costs a browser tab showing the
    /// Dropbox web page — exactly what the user didn't want — while waiting
    /// costs a few more seconds with the menu bar icon showing it's working. So
    /// leave real headroom above the slow case, and rely on the deadline only
    /// for genuinely unreachable Dropbox.
    /// Settable under Advanced → Lookup timeout for the cases the default can't
    /// cover: a slow link, or an impatient user who would rather have the
    /// browser tab immediately.
    static var deadline: Double { Config.lookupTimeout }

    /// Should this URL be intercepted, or handed straight to the browser?
    static func isShareLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "dropbox.com" || host.hasSuffix(".dropbox.com") else { return false }

        // Never intercept our own OAuth flow, the developer console, or account pages.
        let path = url.path.lowercased()
        for prefix in ["/oauth2", "/developers", "/account", "/login", "/logout", "/settings"] {
            if path.hasPrefix(prefix) { return false }
        }
        return true
    }

    /// The API is fussy about share-link query strings, so try a few forms.
    ///
    /// Every extra form is another sequential round trip on a click, so the list
    /// is kept as short as correctness allows. In particular the query-stripped
    /// form is only offered for legacy `/s/` links: on a modern `/scl/` link the
    /// `rlkey` *is* the access credential, so asking without it is a guaranteed
    /// failure — a round trip spent to be told no.
    static func variants(of url: URL) -> [String] {
        let out = ordered(shapes(of: url))
        return out.isEmpty ? [url.absoluteString] : out
    }

    /// The forms worth asking about, in their natural order.
    private static func shapes(of url: URL) -> [(shape: String, value: String)] {
        var out = [(shape: "full", value: url.absoluteString)]
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return out
        }
        let rlkey = components.queryItems?.first(where: { $0.name == "rlkey" })

        if let rlkey {
            components.queryItems = [rlkey]
            components.fragment = nil
            if let s = components.url?.absoluteString, !out.contains(where: { $0.value == s }) {
                out.append((shape: "rlkey", value: s))
            }
        }

        if !url.path.lowercased().hasPrefix("/scl/") {
            components.queryItems = nil
            components.fragment = nil
            if let s = components.url?.absoluteString, !out.contains(where: { $0.value == s }) {
                out.append((shape: "bare", value: s))
            }
        }

        return out
    }

    /// Put the form that worked last time first.
    ///
    /// The forms are tried one after another, so guessing wrong costs a whole
    /// extra round trip on every new link — the single biggest avoidable chunk
    /// of a cold click. Which form Dropbox accepts is a property of the account
    /// and the link style, not of the individual link, so the answer from the
    /// last successful lookup is a good prediction for the next one. Learned
    /// rather than hardcoded, because guessing it in the source is how it ends
    /// up wrong for someone.
    private static func ordered(_ shapes: [(shape: String, value: String)]) -> [String] {
        guard let preferred = UserDefaults.standard.string(forKey: preferredShapeKey),
              let hit = shapes.first(where: { $0.shape == preferred })
        else { return shapes.map(\.value) }
        return [hit.value] + shapes.filter { $0.shape != preferred }.map(\.value)
    }

    private static let preferredShapeKey = "preferredLinkShape"

    /// Called with the form that Dropbox actually accepted.
    static func rememberShape(of url: URL, matching value: String) {
        guard let shape = shapes(of: url).first(where: { $0.value == value })?.shape else { return }
        UserDefaults.standard.set(shape, forKey: preferredShapeKey)
    }

    // MARK: - Entry point

    static func resolve(_ url: URL) async -> ResolveOutcome {
        // Fast path. If this link resolved before and the file is still sitting
        // where it did, reveal it now — no token, no round trip, no waiting.
        //
        // This cache used to be consulted only *after* a live lookup had failed,
        // so every click paid for the network even when the answer was already
        // known. Correct, but it made the common case — clicking a link from the
        // same thread twice — as slow as the rare one. The freshness argument is
        // handled instead by re-checking in the background: `lookup` already
        // refuses a path that has gone, and anything that moved is corrected
        // before the next click.
        if Config.isConfigured, let hit = ResolvedCache.lookup(url) {
            // Only re-check an entry that has gone stale. Confirming on *every*
            // click meant a token refresh and a full round trip per link for a
            // fact that almost never changes — the cost of the fast path,
            // charged in the background instead of the foreground.
            if hit.needsRevalidation {
                Task.detached(priority: .utility) {
                    _ = await resolveNow(url, allowFallbacks: false)
                }
            }
            return .revealed(path: hit.path, via: "remembered", trace: "cache hit, no network")
        }

        let timedOut = ResolveOutcome.failed(ResolveFailure(
            headline: "Dropbox did not respond in time",
            detail: "Gave up after \(Int(deadline)) seconds. The link was opened in the browser.",
            kind: .offline
        ))

        return await withDeadline(seconds: deadline, fallback: timedOut) {
            await resolveNow(url)
        }
    }

    // MARK: - The real work

    /// `allowFallbacks` is false for the background re-check behind a cache hit.
    /// The user already has their file; all that run wants is to correct the
    /// remembered path, and a Spotlight sweep on every click — which is what the
    /// filename fallback would do while Dropbox is unreachable — is a real cost
    /// for no benefit.
    private static func resolveNow(
        _ url: URL,
        allowFallbacks: Bool = true
    ) async -> ResolveOutcome {
        guard Config.isConfigured else {
            return .failed(ResolveFailure(
                headline: "Unbox is not set up",
                detail: "Open Unbox from the menu bar and connect a Dropbox account.",
                kind: .notSetUp
            ))
        }

        // Dropbox can be re-linked or moved; don't trust a stale stored path.
        guard let localRoot = Config.currentLocalRoot() else {
            return .failed(ResolveFailure(
                headline: "Dropbox folder not found on this Mac",
                detail: "The connected account's folder has moved. Check the Dropbox desktop "
                      + "app is running and signed in, then reconnect in Settings.",
                kind: .dropboxRootMissing
            ))
        }

        var notes: [String] = []
        var linkName: String?
        var trace = ResolveTrace()

        do {
            var metadata: [String: Any]?
            var lastError: Error?

            // The cached access token can be rejected mid-flight — it expires,
            // or Dropbox invalidates it. Left alone that surfaces as "reconnect
            // in Settings" on a connection that is perfectly fine and would work
            // again after a restart, which is exactly the sort of intermittent
            // failure that makes an app feel unreliable. Refresh and retry once.
            var token = try await TokenProvider.shared.token()
            trace.mark("token")
            var refreshedToken = false

            for (index, variant) in variants(of: url).enumerated() {
                var attempt = 0
                while true {
                    attempt += 1
                    do {
                        metadata = try await DropboxAPI.rpc(
                            "/2/sharing/get_shared_link_metadata",
                            body: ["url": variant],
                            token: token,
                            pathRoot: Config.pathRoot
                        )
                        trace.mark("link lookup #\(index + 1)")
                        rememberShape(of: url, matching: variant)
                        break
                    } catch {
                        trace.mark("link lookup #\(index + 1) failed")
                        if attempt == 1, !refreshedToken, DropboxAPI.isAuthFailure(error) {
                            refreshedToken = true
                            await TokenProvider.shared.invalidate()
                            if let fresh = try? await TokenProvider.shared.token() {
                                token = fresh
                                notes.append("• access token was rejected; refreshed and retried")
                                continue
                            }
                        }
                        lastError = error
                        notes.append("• \(variant) → \(DropboxError.friendly(error))")
                        break
                    }
                }
                if metadata != nil { break }
                // No point asking the same question two more ways.
                if let lastError, DropboxError.isConclusive(lastError) { break }
            }

            guard let metadata else {
                let offline = (lastError as? URLError) != nil
                return await degrade(
                    allowFallbacks: allowFallbacks,
                    url,
                    name: nil,
                    headline: lastError.map { DropboxError.friendly($0) }
                        ?? "Dropbox didn't recognise that link",
                    kind: offline ? .offline : .dropbox,
                    notes: notes
                )
            }

            linkName = metadata["name"] as? String

            guard let pathLower = metadata["path_lower"] as? String else {
                // By far the most likely cause when a team Dropbox exists but
                // isn't the one connected — so say that rather than the generic
                // "add it to your Dropbox" advice, which wouldn't help.
                if Config.likelyWrongAccount, let team = Config.unconnectedTeamName {
                    notes.append(
                        "Connected as a personal Dropbox account, but \(team) is also synced "
                        + "on this Mac. A personal account cannot resolve a team link. "
                        + "Reconnect as that account in Settings."
                    )
                    return await degrade(
                        allowFallbacks: allowFallbacks,
                        url,
                        name: linkName,
                        headline: "Connected to the wrong Dropbox account",
                        kind: .dropbox,
                        notes: notes
                    )
                }

                notes.append(
                    "Dropbox recognised the link, but it is not inside the connected "
                    + "account. Open it on the web once and choose \"Add to Dropbox\". It "
                    + "will resolve from then on."
                )
                return await degrade(
                    allowFallbacks: allowFallbacks,
                    url,
                    name: linkName,
                    headline: "Link is not in this Dropbox account",
                    kind: .dropbox,
                    notes: notes
                )
            }

            // This used to call files/get_metadata first, purely to get the real
            // capitalisation — a second full round trip on every single link, for
            // something LocalLookup already handles by matching each path
            // component case-insensitively. Try the disk first; only pay for the
            // extra call on a miss, where the nicer path is worth having anyway.
            var dropboxPath = pathLower
            var located = LocalLookup.locate(dropboxPath: pathLower, root: localRoot)
            trace.mark("disk")

            if located.isMiss,
               let full = try? await DropboxAPI.rpc(
                   "/2/files/get_metadata",
                   body: ["path": pathLower],
                   token: token,
                   pathRoot: Config.pathRoot
               ),
               let display = full["path_display"] as? String,
               display != pathLower {
                dropboxPath = display
                located = LocalLookup.locate(dropboxPath: display, root: localRoot)
                trace.mark("real-case lookup + disk")
            }

            switch located {

            case .found(let path):
                ResolvedCache.remember(url, path: path)
                return .revealed(path: path, via: "Dropbox", trace: trace.summary)

            case .rootMissing(let root):
                return .failed(ResolveFailure(
                    headline: "Dropbox folder not found on this Mac",
                    detail: "Expected at \(root). Check the Dropbox desktop app is running "
                          + "and signed in.",
                    kind: .dropboxRootMissing
                ))

            case .notSynced(let missing, let deepest, let isLeaf):
                // A perfectly ordinary situation when selective sync is in use.
                let what = (missing as NSString).lastPathComponent
                let headline = isLeaf
                    ? "\"\(what)\" has not synced to this Mac"
                    : "The folder \"\(what)\" is not synced to this Mac"

                notes.append(
                    isLeaf
                    ? "Dropbox has the file at \(dropboxPath). It has not arrived locally "
                      + "yet; a large file may still be downloading."
                    : "Dropbox has it at \(dropboxPath), but \(missing) is excluded from sync "
                      + "on this Mac. Include it in Dropbox → Preferences → Sync → Selective "
                      + "Sync to open this link in Finder."
                )

                return .failed(ResolveFailure(
                    headline: headline,
                    detail: notes.joined(separator: "\n"),
                    kind: .notSynced,
                    dropboxPath: dropboxPath,
                    nearestLocalFolder: deepest,
                    trace: trace.summary
                ))
            }

        } catch {
            let offline = (error as? URLError) != nil
            return await degrade(
                allowFallbacks: allowFallbacks,
                url,
                name: linkName,
                headline: DropboxError.friendly(error),
                kind: offline ? .offline : .dropbox,
                notes: notes + [DropboxError.friendly(error)]
            )
        }
    }

    // MARK: - Degrading gracefully

    /// The last thing to try once the live lookup hasn't worked. A remembered
    /// path was already ruled out by `resolve`, so this is the filename match.
    private static func degrade(
        allowFallbacks: Bool,
        _ url: URL,
        name: String?,
        headline: String,
        kind: ResolveFailure.Kind,
        notes: [String]
    ) async -> ResolveOutcome {
        var notes = notes
        var trace = ResolveTrace()

        // Past the deadline the browser already has the link, and `withDeadline`
        // cancelled us. Without this check a timed-out lookup went on to fetch
        // the share page and run mdfind across every Dropbox root — seconds of
        // work whose result nothing can use.
        if Task.isCancelled {
            return .failed(ResolveFailure(
            headline: headline,
            detail: notes.joined(separator: "\n"),
            kind: kind,
            trace: trace.summary
        ))
        }

        guard allowFallbacks, Config.nameSearchFallback else {
            return .failed(ResolveFailure(
            headline: headline,
            detail: notes.joined(separator: "\n"),
            kind: kind,
            trace: trace.summary
        ))
        }

        var candidateName = name
        if candidateName == nil {
            candidateName = await FallbackSearch.scrapeName(from: url)
            trace.mark("fallback: read name from share page")
        }
        guard let candidateName, !candidateName.isEmpty else {
            notes.append("Filename fallback: could not read a name from the share page. "
                         + "It most likely requires a login.")
            return .failed(ResolveFailure(
            headline: headline,
            detail: notes.joined(separator: "\n"),
            kind: kind,
            trace: trace.summary
        ))
        }

        let roots = DropboxRoots.read().map(\.root).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        let hits = await FallbackSearch.spotlight(name: candidateName, roots: roots)
        trace.mark("fallback: Spotlight over \(roots.count) root(s)")

        if hits.count == 1 {
            ResolvedCache.remember(url, path: hits[0])
            return .revealed(path: hits[0], via: "filename match", trace: trace.summary)
        }
        if hits.count > 1 {
            notes.append(
                "Filename fallback: \(hits.count) files on this Mac are named "
                + "\"\(candidateName)\". Choosing between them is not safe, so the link "
                + "was opened in the browser."
            )
            return .failed(ResolveFailure(
                headline: "Multiple files named \"\(candidateName)\"",
                detail: notes.joined(separator: "\n"),
                kind: .ambiguous,
                trace: trace.summary
            ))
        }

        notes.append("Filename fallback: no file on this Mac is named \"\(candidateName)\".")
        return .failed(ResolveFailure(
            headline: headline,
            detail: notes.joined(separator: "\n"),
            kind: kind,
            trace: trace.summary
        ))
    }
}

// MARK: - Deadline helper

/// Runs `operation`, returning `fallback` if it hasn't finished within `seconds`.
///
/// The group cancels the loser, but a task group only returns once *every* child
/// has finished — so this bounds the wait only as far as `operation` honours
/// cancellation. URLSession does; `degrade` has to check `Task.isCancelled`
/// itself, or its fallback searches would run on past the deadline and hold the
/// caller here while they did.
func withDeadline<T: Sendable>(
    seconds: Double,
    fallback: T,
    operation: @escaping @Sendable () async -> T
) async -> T {
    await withTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return fallback
        }
        let first = await group.next() ?? fallback
        group.cancelAll()
        return first
    }
}

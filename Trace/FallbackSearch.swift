import Foundation

/// The no-API path: work out what the link is *called*, then look for that name on disk.
///
/// This is deliberately conservative. It only ever acts on a single unambiguous match,
/// because opening the wrong file is worse than opening the browser.
enum FallbackSearch {

    /// Pulls the file or folder name out of the share page's HTML.
    /// Returns nil for links that need a login (most team-restricted ones).
    static func scrapeName(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        // Deliberately shorter than the resolver's overall deadline — a slow
        // share page must never be the reason a click hangs.
        request.timeoutInterval = 4
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        if let name = firstMatch(
            in: html,
            pattern: "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)[\"']"
        ) { return clean(name) }

        if let name = firstMatch(
            in: html,
            pattern: "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:title[\"']"
        ) { return clean(name) }

        if let title = firstMatch(in: html, pattern: "<title[^>]*>([^<]+)</title>") {
            return clean(title)
        }
        return nil
    }

    /// Spotlight for an exact filename under the given roots.
    ///
    /// Async because the work underneath is a blocking `Process` read. Swift's
    /// cooperative thread pool has one thread per core and no way to grow, so
    /// parking one of them for up to three seconds per root can stall unrelated
    /// tasks — including the next click. GCD's pool does grow, so the blocking
    /// happens there instead.
    static func spotlight(name: String, roots: [String]) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: spotlightBlocking(name: name, roots: roots))
            }
        }
    }

    private static func spotlightBlocking(name: String, roots: [String]) -> [String] {
        var hits: [String] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", root, "-name", name]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else { continue }

            // Spotlight over a large Dropbox tree can take a long time, and
            // readDataToEndOfFile blocks until it finishes. Cap it.
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n").map(String.init) {
                // mdfind -name is a substring match, so insist on an exact basename.
                if (line as NSString).lastPathComponent == name, !hits.contains(line) {
                    hits.append(line)
                }
            }
        }
        return hits
    }

    // MARK: - Helpers

    private static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Dropbox", " – Dropbox", " | Dropbox"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

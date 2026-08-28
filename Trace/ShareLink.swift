import Foundation

/// What counts as a Dropbox share link, and which forms of one are worth asking
/// the API about.
///
/// Split out of `LinkResolver` because it is the one part of resolving that is
/// pure: a URL in, a decision or a list of strings out, no network, no disk, no
/// account. That makes it the part worth testing directly, and the part most
/// able to be quietly wrong — a mis-shaped variant costs a round trip per click
/// and shows up only as "clicking links feels slow".
enum ShareLink {

    /// Should this URL be intercepted, or handed straight to the browser?
    static func shouldIntercept(_ url: URL) -> Bool {
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
}

import Foundation

/// Turns Dropbox's machine-readable errors into something a person can act on.
///
/// Dropbox replies to a failed RPC with a body like
/// `{"error_summary": "shared_link_not_found/...", "error": {".tag": "shared_link_not_found"}}`
/// which is precise and completely unhelpful to read.
enum DropboxError {

    static func friendly(status: Int, body: String) -> String {
        let tag = errorTag(in: body) ?? ""

        switch tag {
        case "shared_link_not_found":
            return "The link no longer exists, or was never a valid share link."
        case "shared_link_access_denied":
            return "The connected Dropbox account does not have access to this link. "
                 + "If it was shared with another account, reconnect as that account."
        case "unsupported_link_type":
            return "This type of Dropbox link cannot be opened locally."
        case "invalid_access_token", "expired_access_token":
            return "The Dropbox connection has expired. Reconnect in Settings."
        case "missing_scope":
            return "The Dropbox app is missing a permission. On its Permissions tab enable "
                 + "sharing.read, files.metadata.read and account_info.read, press Submit, "
                 + "then disconnect and reconnect here."
        case "invalid_select_user", "invalid_select_admin":
            return "The team account selection was rejected by Dropbox."
        case "not_found", "path/not_found":
            return "Dropbox no longer has a file at that path."
        default:
            break
        }

        switch status {
        case 401:
            return "Dropbox rejected the connection. Reconnect in Settings."
        case 403:
            return "Dropbox refused this request. This is usually a team policy blocking "
                 + "third-party apps; an admin may need to approve it."
        case 429:
            return "Dropbox is rate-limiting requests. Try again in a moment."
        case 500...599:
            return "Dropbox is reporting a server error. Try again shortly."
        default:
            if !tag.isEmpty { return "Dropbox said: \(tag)" }
            return "Dropbox returned an unexpected error (HTTP \(status))."
        }
    }

    /// Anything that isn't an APIError — usually the network.
    static func friendly(_ error: Error) -> String {
        if let apiError = error as? DropboxAPI.APIError {
            return friendly(status: apiError.status, body: apiError.body)
        }
        if let simple = error as? SimpleError {
            return simple.message
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection."
            case .timedOut:
                return "Dropbox did not respond in time."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Could not reach Dropbox."
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    /// Reads the `.tag` out of a Dropbox error body, falling back to error_summary.
    static func errorTag(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return nil }

        if let error = object["error"] as? [String: Any],
           let tag = error[".tag"] as? String {
            // Nested errors look like {".tag":"path","path":{".tag":"not_found"}}
            if let nested = error[tag] as? [String: Any],
               let nestedTag = nested[".tag"] as? String {
                return "\(tag)/\(nestedTag)"
            }
            return tag
        }
        if let summary = object["error_summary"] as? String {
            return summary.components(separatedBy: "/").first
        }
        return nil
    }

    /// Will every form of the same link get this same answer?
    ///
    /// The resolver tries a few URL shapes because Dropbox is fussy about share
    /// link query strings. But an answer about the *account* — no access, bad
    /// token, missing permission — is identical whichever shape you send, so
    /// retrying costs two more round trips to be told the same thing.
    static func isConclusive(_ error: Error) -> Bool {
        // A network failure won't be fixed by a different query string either.
        if error is URLError { return true }

        guard let api = error as? DropboxAPI.APIError else { return false }

        let tag = errorTag(in: api.body) ?? ""
        if ["shared_link_access_denied", "unsupported_link_type", "invalid_access_token",
            "expired_access_token", "missing_scope"].contains(tag) {
            return true
        }
        // Not-found may genuinely be about the URL shape, so that one keeps trying.
        return [401, 403, 429].contains(api.status) || (500...599).contains(api.status)
    }

    /// The scopes this app can't work without.
    static let requiredScopes = ["account_info.read", "files.metadata.read", "sharing.read"]

    /// Given the space-separated `scope` string from a token response,
    /// returns the required scopes that are missing.
    static func missingScopes(in granted: String?) -> [String] {
        guard let granted else { return [] }
        let have = Set(granted.split(separator: " ").map(String.init))
        return requiredScopes.filter { !have.contains($0) }
    }
}

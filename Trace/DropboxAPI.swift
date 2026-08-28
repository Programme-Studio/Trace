import Foundation

enum DropboxAPI {
    static let authorizeEndpoint = "https://www.dropbox.com/oauth2/authorize"
    static let tokenEndpoint = "https://api.dropboxapi.com/oauth2/token"
    static let apiBase = "https://api.dropboxapi.com"

    struct APIError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { DropboxError.friendly(status: status, body: body) }
    }

    /// Is this "your access token is no good", rather than "your request is no
    /// good"? A refresh fixes the first and nothing fixes the second, so it's
    /// worth telling them apart before retrying.
    static func isAuthFailure(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if api.status == 401 { return true }
        let tag = DropboxError.errorTag(in: api.body) ?? ""
        return tag == "invalid_access_token" || tag == "expired_access_token"
    }

    // MARK: - RPC

    /// POST to a /2/... endpoint. Pass `body: nil` for endpoints that take no arguments.
    static func rpc(
        _ path: String,
        body: [String: Any]?,
        token: String,
        pathRoot: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: apiBase + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Well under the 20s default. The resolver gives up after three seconds
        // anyway, and the background re-check — which has no deadline of its own
        // — should not be able to hold a connection open for twenty.
        request.timeoutInterval = 10

        if let pathRoot {
            // Makes returned paths relative to the team root rather than your member folder.
            let selector: [String: String] = [".tag": "root", "root": pathRoot]
            if let data = try? JSONSerialization.data(withJSONObject: selector),
               let string = String(data: data, encoding: .utf8) {
                request.setValue(string, forHTTPHeaderField: "Dropbox-API-Path-Root")
            }
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }

    // MARK: - OAuth

    /// `role` is Dropbox's `require_role`: "work" for a team account, "personal"
    /// for a personal one, nil for either.
    ///
    /// This exists because Dropbox's authorise page reuses whatever session the
    /// browser already has. If you're signed in personally, approving again just
    /// re-approves the personal account — the connection succeeds and only work
    /// links fail, much later. `require_role=work` makes Dropbox insist on a team
    /// account, and `force_reapprove` stops it silently waving through an
    /// approval that already exists.
    static func authorizeURL(appKey: String, challenge: String, role: String?) -> URL {
        var components = URLComponents(string: authorizeEndpoint)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "force_reapprove", value: "true"),
        ]
        if let role {
            items.append(.init(name: "require_role", value: role))
        }
        components.queryItems = items
        return components.url!
    }

    /// Signs the browser out of Dropbox — the reliable way to break a sticky
    /// session when the wrong account keeps being offered.
    static var logoutURL: URL { URL(string: "https://www.dropbox.com/logout")! }

    static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = components.percentEncodedQuery ?? ""

        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(encoded.utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }

    /// Exchanges the pasted authorisation code for a refresh token and records the account.
    /// Returns a human-readable summary of what got connected.
    static func completeAuthorisation(code: String, verifier: String) async throws -> String {
        let appKey = Config.appKey
        guard !appKey.isEmpty else { throw SimpleError("No app key set.") }

        let token = try await tokenRequest([
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "authorization_code",
            "client_id": appKey,
            "code_verifier": verifier,
        ])

        guard let refresh = token["refresh_token"] as? String,
              let access = token["access_token"] as? String
        else {
            throw SimpleError(
                "Dropbox did not return a refresh token. Check the app key, and that the "
                + "app uses scoped access."
            )
        }

        // Catch the single most common setup mistake straight away: permissions that
        // were ticked *after* authorising, or never ticked at all. Without this the
        // failure only shows up later as a baffling error on a perfectly good link.
        let missing = DropboxError.missingScopes(in: token["scope"] as? String)
        if !missing.isEmpty {
            throw SimpleError(
                "Connected, but the Dropbox app is missing these permissions: "
                + missing.joined(separator: ", ")
                + ".\n\nOpen the app's Permissions tab, enable them, press Submit, then "
                + "authorise again. Permissions do not apply to a token already issued."
            )
        }

        let account = try await rpc("/2/users/get_current_account", body: nil, token: access)
        let rootInfo = account["root_info"] as? [String: Any] ?? [:]
        let label = (account["email"] as? String)
            ?? (account["account_id"] as? String)
            ?? "dropbox"

        // A team member has a `team` object, whatever the root model is. This is
        // a far better signal than root_info's tag, which says "user" for any
        // business team not using team spaces.
        let isTeamMember = account["team"] != nil

        guard Keychain.set(refresh, account: label) else {
            throw SimpleError("Could not save the refresh token to the Keychain.")
        }

        Config.accountLabel = label
        Config.isTeamMember = isTeamMember
        Config.rootInfoTag = (rootInfo[".tag"] as? String) ?? "unknown"

        // Namespace and local folder are chosen together and checked against the
        // disk — see `detectRoot`. Deriving the path root from `root_info`'s tag
        // and the local folder from a separate name match is what produced a
        // connection whose two halves disagreed.
        guard let choice = await detectRoot(token: access) else {
            throw SimpleError(
                "No local Dropbox folder for this account in ~/.dropbox/info.json."
            )
        }

        Config.pathRoot = choice.pathRoot
        Config.localRoot = choice.localRoot
        Config.rootMatchScore = choice.score
        await TokenProvider.shared.invalidate()

        if !FileManager.default.fileExists(atPath: choice.localRoot) {
            return "Connected, but \(choice.localRoot) does not exist on this Mac. Check "
                 + "the Dropbox desktop app is signed in to this account and synced."
        }

        if choice.score == 0 {
            return "Connected as \(label), but none of the folders Dropbox reports were "
                 + "found in \(choice.localRoot). That folder is probably wrong. Use "
                 + "\"Change…\" to select the correct Dropbox folder."
        }
        return ""
    }
}

extension DropboxAPI {
    /// The top-level folders this connection can actually see.
    ///
    /// Worth surfacing during setup: an app created with *App folder* access
    /// instead of *Full Dropbox* connects perfectly happily and then sees exactly
    /// one folder — its own. Showing the list makes that mistake obvious straight
    /// away rather than a week later on a link that should have worked.
    static func visibleTopLevel() async -> [String] {
        guard let token = try? await TokenProvider.shared.token() else { return [] }
        return await visibleTopLevel(token: token)
    }

    static func visibleTopLevel(token: String) async -> [String] {
        await visibleTopLevel(token: token, pathRoot: Config.pathRoot)
    }

    static func visibleTopLevel(token: String, pathRoot: String?) async -> [String] {
        guard let result = try? await rpc(
            "/2/files/list_folder",
            body: ["path": "", "limit": 100],
            token: token,
            pathRoot: pathRoot
        ) else { return [] }

        let entries = result["entries"] as? [[String: Any]] ?? []
        return entries
            .compactMap { $0["name"] as? String }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

extension DropboxAPI {

    /// Which namespace the API should resolve paths against, and which folder on
    /// this Mac those paths correspond to.
    struct RootChoice {
        let pathRoot: String?
        let localRoot: String
        /// How many of the namespace's top-level folders were found in `localRoot`.
        let score: Int
        let topLevel: [String]

        var describesTeamRoot: Bool { pathRoot != nil }
    }

    /// Pick both halves together, and verify the pair against the disk.
    ///
    /// These two settings are meaningless apart. The API returns paths relative
    /// to a namespace; the app joins them onto a local folder. Choose the
    /// namespace from one signal and the folder from another and you get a
    /// connection that authorises cleanly, lists folders cleanly, and then fails
    /// every single team link — which is exactly what happened here: paths were
    /// resolving against the member folder (`~/…/Dropbox-Saentys/Peter Bruce`)
    /// while the local root pointed at the team root (`~/…/Dropbox-Saentys`).
    ///
    /// The old code gated the path root on `root_info[".tag"] == "team"`.
    /// `DropboxRoots.bestMatch` had already learned that that tag lies — plenty
    /// of Business teams report "user" — but this half never got the same
    /// treatment. So don't ask what kind of account it is; ask which pairing
    /// actually matches what's on the disk.
    ///
    /// Candidates are tried in priority order rather than by best score,
    /// because the team namespace *contains* the member folder: it resolves
    /// strictly more links, even when the member folder happens to match more
    /// names.
    static func detectRoot(token: String) async -> RootChoice? {
        let account = try? await rpc("/2/users/get_current_account", body: nil, token: token)
        let rootInfo = account?["root_info"] as? [String: Any] ?? [:]
        let rootNamespace = rootInfo["root_namespace_id"] as? String
        let homeNamespace = rootInfo["home_namespace_id"] as? String

        let accounts = DropboxRoots.read()

        var candidates: [(pathRoot: String?, localRoots: [String])] = []
        if let rootNamespace, rootNamespace != homeNamespace {
            candidates.append((rootNamespace, accounts.compactMap(\.teamRoot)))
        }
        candidates.append((nil, accounts.map(\.memberRoot)))

        var fallback: RootChoice?

        for candidate in candidates {
            let names = await visibleTopLevel(token: token, pathRoot: candidate.pathRoot)
            guard !names.isEmpty else { continue }
            let wanted = Set(names.map { $0.lowercased() })

            for root in candidate.localRoots {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root)
                else { continue }
                let score = wanted.intersection(Set(entries.map { $0.lowercased() })).count
                let choice = RootChoice(
                    pathRoot: candidate.pathRoot,
                    localRoot: root,
                    score: score,
                    topLevel: names
                )
                // First pairing that actually verifies wins.
                if score > 0 { return choice }
                if fallback == nil { fallback = choice }
            }
        }
        return fallback
    }

    /// Re-run detection against the live account and store the result.
    /// Returns a sentence describing what changed, for the settings window.
    static func repairRoot() async -> String {
        guard let token = try? await TokenProvider.shared.token() else {
            return "Could not reach Dropbox. Check the connection."
        }
        guard let choice = await detectRoot(token: token) else {
            return "Could not determine which Dropbox folder this account maps to."
        }

        let wasPathRoot = Config.pathRoot
        let wasLocalRoot = Config.localRoot

        Config.pathRoot = choice.pathRoot
        Config.localRoot = choice.localRoot
        Config.rootMatchScore = choice.score

        if wasPathRoot == choice.pathRoot && wasLocalRoot == choice.localRoot {
            return choice.score > 0
                ? "Already correct — \(choice.score) of this account's top-level folders "
                  + "were found in \(choice.localRoot)."
                : "No change, and nothing verified: none of the folders Dropbox reports "
                  + "were found in \(choice.localRoot). Use \"Change…\" to select it."
        }

        return "Fixed. Paths now resolve against "
             + (choice.describesTeamRoot ? "the team root" : "your member folder")
             + ", matched to \(choice.localRoot) (\(choice.score) folders verified)."
    }
}

/// Holds the short-lived access token and refreshes it when it's close to expiring.
actor TokenProvider {
    static let shared = TokenProvider()

    private var accessToken: String?
    private var expiry = Date.distantPast

    func invalidate() {
        accessToken = nil
        expiry = .distantPast
    }

    func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(120) { return accessToken }

        guard let label = Config.accountLabel else {
            throw SimpleError("No Dropbox account connected yet.")
        }
        guard let refresh = Keychain.get(account: label) else {
            throw SimpleError("No refresh token in the Keychain for \(label). Reconnect the account.")
        }

        let response = try await DropboxAPI.tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Config.appKey,
        ])
        guard let token = response["access_token"] as? String else {
            throw SimpleError("Dropbox didn't return an access token.")
        }
        accessToken = token
        expiry = Date().addingTimeInterval((response["expires_in"] as? Double) ?? 14400)
        return token
    }
}

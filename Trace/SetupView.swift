import AppKit
import SwiftUI

struct SetupView: View {
    private let state = AppState.shared

    // Install
    @State private var needsInstall = Installer.isRunningFromBuildFolder
    @State private var installing = false
    @State private var installMessage = ""

    // Step 1
    @State private var browsers: [BrowserApp] = []
    @State private var selectedBrowser = Config.fallbackBrowserID ?? ""

    // Step 2
    @State private var appKey = Config.customAppKey
    @State private var pkce: PKCE?
    @State private var code = ""
    @State private var accountLabel = Config.accountLabel
    @State private var localRoot = Config.localRoot ?? ""
    @State private var isTeam = Config.pathRoot != nil
    @State private var connectError = ""
    @State private var connectWarning = ""
    @State private var connecting = false
    @State private var visibleFolders: [String] = []
    @State private var repairingRoot = false
    /// Lowercased names of what's actually on disk at the top of the local root.
    /// Cheap to recompute — one directory read — so it's never cached beyond the
    /// next filesystem event.
    @State private var syncedTopLevel: Set<String> = []
    @State private var watcher = FolderWatcher()
    /// Dropbox's `require_role`. Defaults to "work" when a team Dropbox is synced
    /// on this Mac, since that's overwhelmingly the account you'll want.
    @State private var accountRole: String =
        DropboxRoots.read().contains { $0.isTeam } ? "work" : ""

    // Step 3
    @State private var testLink = ""
    @State private var testing = false
    @State private var testPath: String?
    @State private var testVia = ""
    @State private var testFailure: ResolveFailure?
    /// A test that reaches Dropbox proves the connection works, even if the file
    /// turns out not to be synced locally — so that counts as step 3 done.
    @State private var testProvedConnection = false

    // Step 4
    @State private var isDefault = false
    @State private var makingDefault = false
    @State private var defaultError = ""
    @State private var eligibility = ""

    // Options
    @State private var loginItemOn = false
    @State private var nameFallback = Config.nameSearchFallback
    @State private var openInNewTab = Config.openInNewTab
    @State private var safariPermission = SafariTab.Permission.unknown
    @State private var askingSafari = false
    @State private var revealBehaviour = Config.revealBehaviour
    @State private var keepHistory = Config.keepHistory
    @State private var lookupTimeout = Config.lookupTimeout
    @State private var handingBack = false
    @State private var confirmReset = false
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    @State private var optionsMessage = ""

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    let model: SettingsModel

    private var isConnected: Bool { accountLabel != nil }

    /// Nothing left to do. The window's whole shape turns on this: a checklist
    /// you work through once shouldn't still be a checklist a month later.
    private var isSetUp: Bool { isConnected && isDefault && !needsInstall }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The page title, matching System Settings' "Accessibility" and
                // Music's "Home" — both put a large title as the literal first
                // element of the scrolling content, not floating chrome. That's
                // what was missing: without one, the first card had nothing
                // anchoring the top of the pane, so no padding value was ever
                // going to look right. Skipped for `.about`, which already has
                // its own icon-and-name card acting as its header — a second
                // "Trace" title above that would just repeat it.
                if model.pane != .about {
                    Text(model.pane.title)
                        .font(.largeTitle.bold())
                }

                if needsInstall { installBanner }
                if !optionsMessage.isEmpty {
                    CalloutBox(text: optionsMessage, kind: .info)
                }

                switch model.pane {
                case .status:   statusPane
                case .general:  generalPane
                case .dropbox:  dropboxPane
                case .activity: activityPane
                case .advanced: advancedPane
                case .about:    aboutPane
                }
            }
            // Plain, even padding. AppKit now positions this pane correctly on
            // its own — see `NSTrackingSeparatorToolbarItem` in
            // SettingsSplit.swift — so there's no toolbar band left to
            // manually compensate for here.
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The detail pane is automatically inset ~66pt for the title bar +
        // toolbar band — real, and stable, but not what a Settings-style page
        // wants: verified via a findable anchor view that the title otherwise
        // sits fully 86pt from the window's top edge, far more than the ~20pt
        // gap System Settings and Music both use next to their own traffic
        // lights. `ignoresSafeArea` discards that automatic reservation and
        // this replaces it with a small deliberate one instead — confirmed
        // stable at exactly 20pt across repeated resizes, unlike every
        // measurement taken before this that drifted while the window settled.
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 20) }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            refresh()
            watchLocalRoot()
            if !isSetUp, state.pendingTestLink == nil, testLink.isEmpty {
                model.pane = isConnected ? .general : .dropbox
            }
        }
        .onDisappear { watcher.stop() }
        .onReceive(ticker) { _ in
            isDefault = state.isDefaultBrowser
            loginItemOn = LoginItem.isEnabled
            needsInstall = Installer.isRunningFromBuildFolder
            autofillCodeFromClipboard()
            adoptPendingLink()
        }
    }

    // MARK: - Status

    private var statusPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneBanner(
                ok: isSetUp,
                title: isSetUp ? "Ready" : "Setup incomplete",
                message: isSetUp
                    ? "Dropbox links open in Finder. Everything else goes to your browser."
                    : "Complete the items marked below to start handling Dropbox links."
            )

            Card {
                SettingRow(
                    "Handling web links",
                    description: isDefault
                        ? "Dropbox links open in Finder. Other links go to "
                          + Browser.name(forBundleID: selectedBrowser) + "."
                        : "Requires Trace to be the default browser. macOS provides no "
                          + "other way to receive a clicked link."
                ) {
                    if isDefault {
                        StatusPill(text: "Active", tone: .good)
                    } else {
                        Button("Set up") { model.pane = .general }
                    }
                }
                CardDivider()
                SettingRow(
                    "Dropbox account",
                    description: accountLabel ?? "No account connected."
                ) {
                    if isConnected {
                        StatusPill(text: "Connected", tone: .good)
                    } else {
                        Button("Connect") { model.pane = .dropbox }
                    }
                }
            }

            testLinkCard

            connectionWarnings
        }
    }

    /// Lives on Status rather than Activity: "why didn't that link work?" is a
    /// question about whether the app is working, and this is the one control
    /// that answers it directly.
    private var testLinkCard: some View {
        Card {
            SettingRow(
                "Test a link",
                description: "Paste a Dropbox link to see where it resolves to, or why "
                           + "it does not."
            )
            CardDivider()
            VStack(alignment: .leading, spacing: 10) {
                testLinkControls
                testLinkResult
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
        }
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                SettingRow(
                    "Default web browser",
                    description: DefaultBrowser.systemDefaultURL()
                        .map { "Currently \(Browser.name(of: $0))." } ?? "Currently unset."
                ) {
                    HStack(spacing: 8) {
                        if makingDefault { ProgressView().controlSize(.small) }
                        if isDefault {
                            StatusPill(text: "Trace", tone: .good)
                        } else {
                            Button("Make Trace the default") { makeDefault() }
                                .buttonStyle(.borderedProminent)
                                .disabled(makingDefault || needsInstall)
                        }
                    }
                }
                CardDivider()
                SettingRow(
                    "System Settings",
                    description: "Trace is listed under Desktop & Dock → Default web "
                               + "browser."
                ) {
                    Button("Open") { DefaultBrowser.openSystemSettings() }
                }
                if isDefault {
                    CardDivider()
                    // The way out. Leaving this to System Settings assumes the
                    // user knows where the setting lives, which is the one thing
                    // someone who wants to stop using Trace reliably doesn't.
                    SettingRow(
                        "Stop handling links",
                        description: "Hands the default-browser slot back to "
                                   + Browser.name(forBundleID: selectedBrowser)
                                   + ". Trace keeps its settings and its Dropbox connection."
                    ) {
                        HStack(spacing: 8) {
                            if handingBack { ProgressView().controlSize(.small) }
                            Button("Give it back") { handBackDefault() }
                                .disabled(handingBack || selectedBrowser.isEmpty)
                        }
                    }
                }
            }

            if !defaultError.isEmpty { CalloutBox(text: defaultError, kind: .error) }
            if needsInstall {
                CalloutBox(
                    text: "Move the app to a permanent location first, using the button "
                        + "above. macOS will not accept a default browser inside Xcode's "
                        + "build folder.",
                    kind: .warning
                )
            }

            Card {
                SettingRow(
                    "Other links open in",
                    description: "Links that are not Dropbox share links are passed "
                               + "through unchanged."
                ) {
                    browserPicker.fixedSize()
                }
                CardDivider()
                SettingRow(
                    "Start automatically at login",
                    description: "Links can only be handled while Trace is running."
                ) {
                    Toggle("", isOn: Binding(
                        get: { loginItemOn },
                        set: { newValue in
                            loginItemOn = newValue
                            optionsMessage = LoginItem.set(newValue) ?? ""
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                CardDivider()
                SettingRow(
                    "Match by filename as a last resort",
                    description: "If Dropbox cannot place a link, search this Mac for a file "
                               + "of that name. Acts only on a single exact match. Anything "
                               + "ambiguous opens in the browser."
                ) {
                    Toggle("", isOn: $nameFallback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: nameFallback) {
                            Config.nameSearchFallback = nameFallback
                        }
                }
                if selectedBrowser == SafariTab.bundleID {
                    // Safari-only, because it is the only browser that opens a
                    // window here — so a row about it anywhere else would be a
                    // control with nothing to control.
                    CardDivider()
                    SettingRow(
                        "Open links in a new tab",
                        description: safariTabDescription
                    ) {
                        HStack(spacing: 8) {
                            if openInNewTab, safariPermission == .notAsked {
                                Button("Allow…") { askSafariPermission() }
                                    .disabled(askingSafari)
                            }
                            if openInNewTab, safariPermission == .denied {
                                Button("Open Settings") {
                                    SafariTab.openAutomationSettings()
                                }
                            }
                            Toggle("", isOn: Binding(
                                get: { openInNewTab },
                                set: { newValue in
                                    openInNewTab = newValue
                                    Config.openInNewTab = newValue
                                    safariPermission = SafariTab.permission
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
                CardDivider()
                SettingRow(
                    "When a link resolves",
                    description: revealBehaviour == .reveal
                        ? "Finder opens with the file selected."
                        : "The file opens in whichever app handles it. Folders are "
                          + "revealed either way."
                ) {
                    Picker("", selection: $revealBehaviour) {
                        ForEach(Config.Reveal.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: revealBehaviour) {
                        Config.revealBehaviour = revealBehaviour
                    }
                }
            }
        }
    }

    /// Says what will actually happen, which for this row means saying where the
    /// permission stands. A toggle that is on but blocked is otherwise
    /// indistinguishable from one that is working.
    private var safariTabDescription: String {
        guard openInNewTab else {
            return "Links open in a new Safari window, which is Safari's own default."
        }
        switch safariPermission {
        case .granted:
            return "Links join Safari's current window instead of opening a new one."
        case .notAsked:
            return "Needs permission to control Safari. macOS will ask the first time a "
                 + "link opens in the browser, or ask it now."
        case .denied:
            return "Permission to control Safari was refused, so links open in a new "
                 + "window. Turn Trace on under Privacy & Security → Automation."
        case .unknown:
            return "Links join Safari's current window instead of opening a new one, "
                 + "when macOS allows Trace to control Safari."
        }
    }

    private func askSafariPermission() {
        askingSafari = true
        SafariTab.requestPermission {
            safariPermission = SafariTab.permission
            askingSafari = false
        }
    }

    // MARK: - Dropbox

    private var dropboxPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let accountLabel {
                Card {
                    SettingRow("Account", description: accountLabel) {
                        StatusPill(text: "Connected", tone: .good)
                    }
                    CardDivider()
                    SettingRow(
                        "Local folder",
                        description: localRoot.isEmpty ? "Not set" : localRoot
                    ) {
                        Button("Change…") { chooseLocalRoot() }
                    }
                }

                connectionWarnings
                visibleFoldersCard

                Card {
                    // Disconnecting drops the token this Mac holds; it does not
                    // revoke Trace's access on Dropbox's side. Anyone who
                    // disconnects because they no longer want the app to have
                    // access needs the second half too.
                    SettingRow(
                        "Access on dropbox.com",
                        description: "Disconnecting removes the token stored on this Mac. "
                                   + "Revoke Trace under Connected apps to withdraw access "
                                   + "for good."
                    ) {
                        Button("Connected apps") {
                            Browser.open(
                                URL(string:
                                    "https://www.dropbox.com/account/connected_apps")!
                            )
                        }
                    }
                    CardDivider()
                    SettingRow(
                        "Disconnect this account",
                        description: "Removes the stored token. Requires authorising again."
                    ) {
                        HStack(spacing: 8) {
                            Button("Sign out in browser") {
                                Browser.open(DropboxAPI.logoutURL)
                            }
                            Button("Disconnect") { disconnect() }
                        }
                    }
                }
            } else {
                PaneBanner(
                    ok: false,
                    title: "Not connected",
                    message: "Trace needs permission from Dropbox to look links up. "
                           + "This is a one-time setup."
                )
                Card { connectForm.padding(15) }
                if !connectError.isEmpty { CalloutBox(text: connectError, kind: .error) }
                if !connectWarning.isEmpty { CalloutBox(text: connectWarning, kind: .warning) }
            }
        }
    }

    private var visibleFoldersCard: some View {
        Card {
            SettingRow(
                "Folders in this account",
                description: visibleFolders.isEmpty
                    ? "Nothing reported yet."
                    : "\(syncedTopLevel.count) of \(visibleFolders.count) synced to this Mac. "
                      + "Links into an unsynced folder open in the browser. Updates "
                      + "automatically when selective sync changes."
            ) {
                Button("Refresh") { loadVisibleFolders() }
            }

            if !visibleFolders.isEmpty {
                CardDivider()
                VStack(alignment: .leading, spacing: 5) {
                    // Dropbox's listing is server-side and doesn't change when
                    // you alter selective sync — that's a local decision. So
                    // each row is annotated from a directory read costing
                    // microseconds, refreshed by a filesystem event, rather than
                    // by re-asking Dropbox for something it can't tell us.
                    ForEach(visibleFolders, id: \.self) { folder in
                        let synced = syncedTopLevel.contains(folder.lowercased())
                        HStack(spacing: 7) {
                            Image(systemName: synced
                                  ? "checkmark.circle.fill" : "arrow.down.circle.dotted")
                                .foregroundStyle(synced ? Color.green : Color.secondary)
                            Text(folder)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(synced ? Color.primary : Color.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    if visibleFolders.count == 1 {
                        CalloutBox(
                            text: "One folder indicates this Dropbox app was created with "
                                + "App folder access instead of Full Dropbox. Team links "
                                + "will not resolve. Create a new app with Full Dropbox "
                                + "access and reconnect.",
                            kind: .error
                        )
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }
        }
    }

    /// The failure this exists for — more than one registered copy of this app —
    /// is invisible from the outside and makes the app look randomly broken:
    /// clicks go to a build folder that was deleted, and System Settings quietly
    /// stops listing the app at all.
    private var registrationCard: some View {
        Card {
            SettingRow(
                "Registration with macOS",
                description: "Each build registers another copy as a web browser. When "
                           + "several copies claim one bundle id, macOS can route clicks to "
                           + "a copy that no longer exists. Repair leaves one."
            ) {
                HStack(spacing: 8) {
                    // Both shell out to lsregister — seconds at best, closer to
                    // a minute for a repair — so neither may run inline on the
                    // main thread.
                    Button("Show status") {
                        eligibility = "Reading LaunchServices…"
                        Task { eligibility = await DefaultBrowser.statusAsync() }
                    }
                    Button("Repair") {
                        eligibility = "Repairing registrations…"
                        Task { eligibility = await DefaultBrowser.repairAsync() }
                    }
                }
            }

            if !eligibility.isEmpty {
                CardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(eligibility)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 190)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(eligibility, forType: .string)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }
        }
    }

    // MARK: - Activity

    /// The app has always assembled a full explanation for every link it opens —
    /// which round trips it made, how long each took, where the file turned out
    /// to be — and then thrown it away: `LogEntry.detail` was recorded and shown
    /// nowhere. This is where it goes, and it's the answer to "why did that one
    /// take two seconds?".
    private var activityPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                SettingRow(
                    "Keep a history of opened links",
                    description: "The last 25 links, held in memory only and lost on quit. "
                               + "Turning this off also empties the menu bar list."
                ) {
                    Toggle("", isOn: Binding(
                        get: { keepHistory },
                        set: { newValue in
                            keepHistory = newValue
                            Config.keepHistory = newValue
                            if !newValue { state.clearHistory() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            Card {
                SettingRow(
                    "Recent links",
                    description: state.entries.isEmpty
                        ? (keepHistory ? "No links opened yet." : "History is turned off.")
                        : "Expand a row for its timing breakdown."
                ) {
                    if !state.entries.isEmpty {
                        Button("Clear") { state.clearHistory() }
                    }
                }

                ForEach(state.entries.prefix(10)) { entry in
                    CardDivider()
                    DisclosureGroup {
                        Text(entry.detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.symbol)
                                .foregroundStyle(entry.success ? Color.green : Color.orange)
                            Text(entry.timeText).foregroundStyle(.secondary)
                            Text(entry.headline).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(entry.durationText).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                SettingRow(
                    "Remembered paths",
                    description: "Resolved locations are cached, so repeat clicks are "
                               + "instant and work while Dropbox is unreachable. "
                               + "\(ResolvedCache.count) stored."
                ) {
                    Button("Forget all") {
                        ResolvedCache.clear()
                        optionsMessage = "Remembered paths cleared."
                    }
                }
                CardDivider()
                SettingRow(
                    "Lookup timeout",
                    description: "How long to wait for Dropbox before giving up and opening "
                               + "the link in the browser. A typical lookup takes under a "
                               + "second; raise this on a slow connection."
                ) {
                    HStack(spacing: 8) {
                        Text("\(Int(lookupTimeout))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: $lookupTimeout, in: 2...30, step: 1)
                            .labelsHidden()
                            .onChange(of: lookupTimeout) {
                                Config.lookupTimeout = lookupTimeout
                            }
                    }
                }
                CardDivider()
                SettingRow(
                    "Diagnostics",
                    description: "Copies connection, routing and recent-link state to the "
                               + "clipboard."
                ) {
                    Button("Copy") { copyDiagnostics() }
                }
            }

            Card {
                SettingRow(
                    "Paths resolve against",
                    description: Config.isTeamMember
                        ? (isTeam
                           ? "The team root. Team folders and your member folder both "
                             + "resolve."
                           : "Your member folder only. Team folders will not resolve.")
                        : "Your personal Dropbox."
                ) {
                    HStack(spacing: 8) {
                        if repairingRoot { ProgressView().controlSize(.small) }
                        Button("Re-check") { repairRoot() }
                            .disabled(repairingRoot)
                    }
                }
            }

            registrationCard

            Card {
                SettingRow(
                    "Reset all settings",
                    description: "Disconnects Dropbox and returns every setting to its "
                               + "default. Does not change your default browser or whether "
                               + "Trace starts at login."
                ) {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog(
                "Reset Trace to its defaults?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { resetEverything() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The Dropbox connection is removed and setup starts again. This cannot "
                     + "be undone.")
            }
        }
    }


    /// Shown only when running from Xcode's build folder.
    private var installBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalloutBox(
                text: "This copy is running from Xcode's build folder. macOS records the "
                    + "default browser by location, so it will stop working after the next "
                    + "clean build.",
                kind: .warning
            )
            HStack {
                Button {
                    installing = true
                    installMessage = ""
                    Installer.installAndRelaunch { problem in
                        installMessage = problem
                        installing = false
                    }
                } label: {
                    Label("Move to \(Installer.destination().deletingLastPathComponent().path) "
                          + "and relaunch", systemImage: "arrow.down.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)

                if installing { ProgressView().controlSize(.small) }
            }
            if !installMessage.isEmpty {
                CalloutBox(text: installMessage, kind: .error)
            }
        }
    }


    /// The connection problems that look like success until a link quietly fails.
    /// These stay at the top level rather than going into Advanced on purpose:
    /// by the time you'd think to go looking for them, you've already lost an
    /// afternoon to a link that opened the wrong thing.
    @ViewBuilder
    private var connectionWarnings: some View {
        if Config.rootMatchUnverified {
            CalloutBox(
                text: "None of the folders Dropbox reports for this account were found in "
                    + "\(localRoot). The folder is probably wrong. Set it under Dropbox → "
                    + "Local folder.",
                kind: .warning
            )
        }

        if Config.likelyWrongAccount, let team = Config.unconnectedTeamName {
            VStack(alignment: .leading, spacing: 8) {
                CalloutBox(
                    text: "This is a personal Dropbox, but \(team) is also synced on this "
                        + "Mac. A personal account cannot resolve team links, so they will "
                        + (Config.nameSearchFallback
                           ? "be matched by filename, which is slower and less reliable."
                           : "open in the browser."),
                    kind: .warning
                )
                Button("Switch to the \(team) account…") { switchToTeamAccount() }
                    .buttonStyle(.borderedProminent)
            }
        }

        if !localRoot.isEmpty && !FileManager.default.fileExists(atPath: localRoot) {
            VStack(alignment: .leading, spacing: 8) {
                CalloutBox(
                    text: "The Dropbox folder is not present on this Mac. Links will open "
                        + "in the browser until the Dropbox desktop app is running and "
                        + "signed in.",
                    kind: .warning
                )
                Button("Look for it again") { findLocalRootAgain() }
            }
        }
    }


    /// One picker, used by both the wizard step and the settings panel.
    private var browserPicker: some View {
        Picker("", selection: $selectedBrowser) {
            Text("Choose…").tag("")
            ForEach(browsers) { app in
                Text(app.name).tag(app.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Browser for non-Dropbox links")
        .onChange(of: selectedBrowser) {
            Config.fallbackBrowserID = selectedBrowser.isEmpty ? nil : selectedBrowser
        }
    }


    /// The default path is one button. Trace ships with its own Dropbox app
    /// registration, so there is nothing to create and nothing to paste — the
    /// developer-console route is still here for anyone who wants to run against
    /// their own key, but it's behind a disclosure because almost nobody does.
    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Dropbox's authorise page reuses whatever session the browser
            // already has, so "sign in as the right one" is not reliably under
            // the user's control. Asking Dropbox to insist on an account type is.
            Picker("Account type", selection: $accountRole) {
                Text("Work / team account").tag("work")
                Text("Personal account").tag("personal")
                Text("Either").tag("")
            }
            .pickerStyle(.radioGroup)

            if accountRole == "work" {
                Hint("Dropbox will require a team account, preventing an already "
                     + "signed-in personal session from being approved by mistake.")
            }

            HStack {
                Button("Connect Dropbox…") { beginAuthorisation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting)
                Button("Sign out of Dropbox first") {
                    Browser.open(DropboxAPI.logoutURL)
                }
            }
            Hint("If Dropbox keeps returning the same account, sign out in the browser "
                 + "first. That clears the existing session.")

            if pkce != nil {
                VStack(alignment: .leading, spacing: 8) {
                    CalloutBox(
                        text: "Sign in as the account whose files you want to open, and "
                            + "approve. Copy the code Dropbox shows; it is pasted below "
                            + "automatically.",
                        kind: .info
                    )
                    HStack {
                        TextField("Paste the code here", text: $code)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") { finishAuthorisation() }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty
                                      || connecting)
                    }
                    if connecting { ProgressView().controlSize(.small) }
                }
                .padding(.top, 2)
            }

            DisclosureGroup("Use my own Dropbox app") {
                VStack(alignment: .leading, spacing: 8) {
                    Hint("Trace uses its own Dropbox registration by default. Supply a key "
                         + "here to run against your own instead. Leave blank to use the "
                         + "built-in one.")

                    VStack(alignment: .leading, spacing: 4) {
                        InstructionRow("a", "Create an app. Choose Scoped access, then Full "
                                       + "Dropbox.")
                        InstructionRow("b", "Full Dropbox is required, not App folder. An "
                                       + "App-folder app cannot see team files, and the "
                                       + "choice is permanent.")
                        InstructionRow("c", "On the Permissions tab, enable the three scopes "
                                       + "below and press Submit.")
                        InstructionRow("d", "Copy the App key from the Settings tab.")
                    }

                    Text(DropboxError.requiredScopes.joined(separator: "   ·   "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack {
                        Button {
                            Browser.open(
                                URL(string: "https://www.dropbox.com/developers/apps")!
                            )
                        } label: {
                            Label("Dropbox app console",
                                  systemImage: "arrow.up.forward.square")
                        }
                        Button("Copy the 3 permissions") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                DropboxError.requiredScopes.joined(separator: "\n"),
                                forType: .string
                            )
                            optionsMessage = "Permission names copied."
                        }
                    }

                    HStack {
                        TextField("App key (optional)", text: $appKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Button("Paste") {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                appKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    .onChange(of: appKey) {
                        Config.customAppKey = appKey.trimmingCharacters(in: .whitespaces)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private var testLinkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("https://www.dropbox.com/scl/…", text: $testLink)
                    .textFieldStyle(.roundedBorder)
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        testLink = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                Button("Test") { runTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected
                              || testLink.trimmingCharacters(in: .whitespaces).isEmpty
                              || testing)
            }

            if testing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking it up…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }


    @ViewBuilder
    private var testLinkResult: some View {
        if let testPath {
            VStack(alignment: .leading, spacing: 6) {
                Label("Found it — via \(testVia)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(testPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: testPath)]
                    )
                }
            }
        }

        if let testFailure {
            VStack(alignment: .leading, spacing: 8) {
                CalloutBox(
                    text: testFailure.headline,
                    kind: testFailure.kind == .notSynced
                        || testFailure.kind == .offline
                        || testFailure.kind == .dropboxRootMissing
                        ? .warning : .error
                )

                if let dropboxPath = testFailure.dropboxPath {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dropbox has it at")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(dropboxPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    if let nearest = testFailure.nearestLocalFolder {
                        Button("Reveal nearest synced folder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: nearest)]
                            )
                        }
                    }
                    if let dropboxPath = testFailure.dropboxPath {
                        Button("Copy Dropbox path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dropboxPath, forType: .string)
                        }
                    }
                }

                if !testFailure.detail.isEmpty {
                    DisclosureGroup("What happened") {
                        Text(testFailure.detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
        }
    }


    // MARK: - Trace

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trace").font(.title2.bold())
                        Text("Version \(Updater.versionString)")
                            .foregroundStyle(.secondary)
                        Text("Dropbox share links open in Finder instead of the browser.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
            }

            Card {
                SettingRow(
                    "Check for updates automatically",
                    description: Updater.shared.lastCheckDescription
                ) {
                    Toggle("", isOn: Binding(
                        get: { autoUpdate },
                        set: { newValue in
                            autoUpdate = newValue
                            Updater.shared.automaticallyChecks = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                CardDivider()
                SettingRow(
                    "Updates",
                    description: "Trace is distributed outside the App Store and updates "
                               + "itself. Downloads are signature-checked before installing."
                ) {
                    Button("Check now") { Updater.shared.checkForUpdates() }
                }
            }

            Card {
                SettingRow(
                    "Source and releases",
                    description: "github.com/Programme-Studio/Trace"
                ) {
                    Button("Open") {
                        Browser.open(
                            URL(string: "https://github.com/Programme-Studio/Trace")!
                        )
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        browsers = Browser.installed()

        if selectedBrowser.isEmpty {
            // Config captured the real pre-existing default at launch; only guess
            // if that somehow didn't happen.
            if let captured = Config.fallbackBrowserID {
                selectedBrowser = captured
            } else if let guess = browsers.first(where: { $0.id == "com.apple.Safari" })
                        ?? browsers.first {
                selectedBrowser = guess.id
                Config.fallbackBrowserID = selectedBrowser
            }
        }

        // A selection with no matching tag makes SwiftUI's Picker misbehave, so
        // make sure whatever is selected is genuinely in the list.
        if !selectedBrowser.isEmpty,
           !browsers.contains(where: { $0.id == selectedBrowser }) {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: selectedBrowser
            ) {
                browsers.append(BrowserApp(id: selectedBrowser,
                                           name: Browser.name(of: url),
                                           url: url))
                browsers.sort {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            } else {
                selectedBrowser = ""
            }
        }

        isDefault = state.isDefaultBrowser
        loginItemOn = LoginItem.isEnabled
        // Only while the row is on screen: this is a TCC lookup, and the ticker
        // runs every two seconds for the whole life of the window.
        if model.pane == .general, selectedBrowser == SafariTab.bundleID {
            safariPermission = SafariTab.permission
        }
        needsInstall = Installer.isRunningFromBuildFolder
        autoUpdate = Updater.shared.automaticallyChecks
        adoptPendingLink()
        if isConnected && visibleFolders.isEmpty { loadVisibleFolders() }
    }

    /// Pick up a link the user clicked in the menu bar history.
    private func adoptPendingLink() {
        guard let link = state.pendingTestLink else { return }
        testLink = link
        testPath = nil
        testFailure = nil
        state.pendingTestLink = nil
        // The test field lives on Status, so go there — otherwise clicking a
        // failed link in the menu bar opens this window on some other pane and
        // appears to have done nothing.
        model.pane = .status
        runTest()
    }

    /// Dropbox shows the authorisation code on a web page for you to copy. Once
    /// it's on the clipboard there's no reason to make anyone paste it by hand.
    private func autofillCodeFromClipboard() {
        guard pkce != nil, code.isEmpty else { return }
        guard let candidate = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { return }

        guard candidate.count >= 20, candidate.count <= 120 else { return }
        guard candidate != Config.appKey else { return }
        guard candidate.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return }

        code = candidate
    }

    /// Recompute what's on disk, and make sure we're watching the right folder.
    /// Called on appear, after a repair, and from the filesystem watcher.
    private func watchLocalRoot() {
        let root = Config.localRoot ?? ""
        syncedTopLevel = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
                .map { $0.lowercased() }
        )
        watcher.start(path: root) { watchLocalRoot() }
    }

    private func loadVisibleFolders() {
        Task { @MainActor in
            let folders = await DropboxAPI.visibleTopLevel()
            if !folders.isEmpty { visibleFolders = folders }
        }
    }

    private func disconnect() {
        Config.disconnect()
        accountLabel = nil
        localRoot = ""
        visibleFolders = []
        testPath = nil
        testFailure = nil
        testProvedConnection = false
        connectError = ""
        connectWarning = ""
    }

    /// Re-run the namespace + local-folder detection against the live account.
    /// This is the fix for a connection whose two halves disagree — the API
    /// resolving paths against the member folder while the local root points at
    /// the team root, which fails every team link while looking perfectly healthy.
    private func repairRoot() {
        repairingRoot = true
        Task { @MainActor in
            optionsMessage = await DropboxAPI.repairRoot()
            localRoot = Config.localRoot ?? ""
            isTeam = Config.pathRoot != nil
            testPath = nil
            testFailure = nil
            loadVisibleFolders()
            watcher.stop()          // localRoot may have moved
            watchLocalRoot()
            repairingRoot = false
        }
    }

    /// Give the default-browser slot back to the browser links already fall
    /// through to.
    private func handBackDefault() {
        handingBack = true
        defaultError = ""
        DefaultBrowser.hand(to: selectedBrowser) { problem in
            Task { @MainActor in
                // The switch isn't instant, and macOS may show its own
                // confirmation, so check the end state rather than the return.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isDefault = state.isDefaultBrowser
                if isDefault {
                    defaultError = problem
                        ?? "macOS reported no error, but Trace is still the default browser. "
                         + "Change it in System Settings → Desktop & Dock."
                } else {
                    optionsMessage = "Links now go to "
                        + Browser.name(forBundleID: selectedBrowser) + "."
                }
                handingBack = false
            }
        }
    }

    private func resetEverything() {
        Config.resetAll()
        disconnect()
        state.clearHistory()
        appKey = ""
        selectedBrowser = Config.fallbackBrowserID ?? ""
        nameFallback = Config.nameSearchFallback
        openInNewTab = Config.openInNewTab
        revealBehaviour = Config.revealBehaviour
        keepHistory = Config.keepHistory
        lookupTimeout = Config.lookupTimeout
        accountRole = DropboxRoots.read().contains { $0.isTeam } ? "work" : ""
        refresh()
        optionsMessage = "Trace has been reset. Connect a Dropbox account to start again."
        model.pane = .dropbox
    }

    private func findLocalRootAgain() {
        if let found = Config.currentLocalRoot() {
            localRoot = found
            optionsMessage = ""
        } else {
            optionsMessage = "Still can't find it. Is the Dropbox desktop app running?"
        }
    }

    /// Escape hatch: point the account at the right Dropbox folder by hand.
    /// Detection is good but this is the thing that always works.
    private func chooseLocalRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Pick the Dropbox folder this account's files are in."
        if let current = Config.localRoot {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Config.localRoot = url.path
        Config.rootMatchScore = 1        // chosen by hand, so treat it as verified
        localRoot = url.path
        testPath = nil
        testFailure = nil
    }

    /// Drop the current connection and immediately start authorising a team
    /// account, without making the user hunt for the account picker.
    private func switchToTeamAccount() {
        disconnect()
        accountRole = "work"
        beginAuthorisation()
    }

    private func beginAuthorisation() {
        Config.customAppKey = appKey.trimmingCharacters(in: .whitespaces)
        connectError = ""
        connectWarning = ""
        let generated = PKCE()
        pkce = generated
        Browser.open(
            DropboxAPI.authorizeURL(
                appKey: Config.appKey,
                challenge: generated.challenge,
                role: accountRole.isEmpty ? nil : accountRole
            )
        )
    }

    private func finishAuthorisation() {
        guard let pkce else { return }
        connecting = true
        connectError = ""
        connectWarning = ""

        Task { @MainActor in
            do {
                let warning = try await DropboxAPI.completeAuthorisation(
                    code: code,
                    verifier: pkce.verifier
                )
                accountLabel = Config.accountLabel
                localRoot = Config.localRoot ?? ""
                isTeam = Config.pathRoot != nil
                connectWarning = warning
                self.pkce = nil
                code = ""
                loadVisibleFolders()
            } catch {
                connectError = DropboxError.friendly(error)
            }
            connecting = false
        }
    }

    private func makeDefault() {
        makingDefault = true
        defaultError = ""

        // Links can only be handled while Trace is running, so taking the
        // browser slot without starting at login is a half-working setup.
        if !LoginItem.isEnabled {
            if let problem = LoginItem.set(true) { optionsMessage = problem }
            loginItemOn = LoginItem.isEnabled
        }

        let before = DefaultBrowser.systemDefaultURL()?.path ?? "none"

        DefaultBrowser.request { problem in
            if let problem, !problem.isEmpty {
                defaultError = "macOS refused: \(problem)"
                makingDefault = false
                return
            }

            // No error doesn't mean it worked. macOS shows its own confirmation
            // dialog and the switch isn't instant, so check what actually
            // happened rather than reporting success on silence.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let after = DefaultBrowser.systemDefaultURL()?.path ?? "none"
                isDefault = state.isDefaultBrowser

                if !isDefault {
                    defaultError =
                        "macOS reported no error, but the handler is still \(after)"
                        + (before == after ? " (unchanged)." : " (was \(before)).")
                        + "\n\nIf no confirmation dialog appeared, macOS declined silently. "
                        + "Run Repair below, then set it in System Settings → Desktop & Dock "
                        + "→ Default web browser."
                }
                makingDefault = false
            }
        }
    }

    private func runTest() {
        testFailure = nil
        testPath = nil

        guard let url = URL(string: testLink.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            testFailure = ResolveFailure(
                headline: "Not a valid link.",
                detail: ""
            )
            return
        }

        testing = true
        Task { @MainActor in
            let started = Date()
            let outcome = await LinkResolver.resolve(url)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            switch outcome {
            case .revealed(let path, let via, let trace):
                testPath = path
                testVia = "\(via), \(elapsed) ms"
                    + (trace.isEmpty ? "" : " — \(trace)")
                testProvedConnection = true
            case .failed(let failure):
                testFailure = failure
                // Reaching Dropbox and being told "it's just not synced here"
                // still proves the connection is working.
                if failure.kind == .notSynced { testProvedConnection = true }
            }
            testing = false
        }
    }

    /// What this bundle actually claims to handle, read back from the built app.
    private func declaredURLSchemes() -> [String] {
        guard let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return ["none — Info.plist didn't make it into the build"] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    private func copyDiagnostics() {
        var lines = [
            "Trace diagnostics",
            "app location: \(Bundle.main.bundleURL.path)",
            "installed properly: \(!Installer.isRunningFromBuildFolder)",
            "connected: \(accountLabel ?? "no")",
            "local root: \(localRoot)",
            "root exists: \(FileManager.default.fileExists(atPath: localRoot))",
            "team member: \(Config.isTeamMember)",
            "root_info tag: \(Config.rootInfoTag)",
            "team namespace: \(Config.pathRoot ?? "none")",
            "visible folders: \(visibleFolders.count) \(visibleFolders.prefix(6))",
            "folder match score: \(Config.rootMatchScore)",
            "default browser: \(isDefault)",
            // Answers "did Info.plist actually make it into the build?" — without
            // these schemes macOS will never offer the app as a browser.
            "declares url schemes: \(declaredURLSchemes().joined(separator: ", "))",
            "fallback browser: \(Config.fallbackBrowserID ?? "none")",
            "name matching: \(Config.nameSearchFallback)",
            "new tab in safari: \(Config.openInNewTab)",
            "safari automation: \(SafariTab.permission.summary)",
            "on resolve: \(Config.revealBehaviour.rawValue)",
            "history: \(Config.keepHistory)",
            "lookup timeout: \(Int(Config.lookupTimeout))s",
            "remembered paths: \(ResolvedCache.count)",
            "login item: \(loginItemOn)",
            "",
            "Dropbox roots on this Mac:",
        ]
        for account in DropboxRoots.read() {
            lines.append("  \(account.key) (team: \(account.isTeam)) → \(account.root)")
        }
        lines.append("")
        lines.append("Recent:")
        for entry in state.entries.prefix(10) {
            lines.append("  [\(entry.timeText)] \(entry.symbol) \(entry.headline)")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        optionsMessage = "Diagnostics copied to the clipboard."
    }
}

// MARK: - Small building blocks

struct InstructionRow: View {
    let marker: String
    let text: String
    init(_ marker: String, _ text: String) {
        self.marker = marker
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker + ".")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CalloutBox: View {
    enum Kind { case info, warning, error }

    let text: String
    let kind: Kind

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

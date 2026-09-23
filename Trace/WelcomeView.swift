import AppKit
import Combine
import SwiftUI

/// The first-run flow.
///
/// Deliberately *not* a pane in the settings window. Setup used to happen by
/// opening Settings and jumping the sidebar to Dropbox, which put a new user in
/// front of the app's entire surface area — six sidebar items, an account-type
/// radio group, and a four-step "create your own Dropbox app" disclosure — with
/// nothing saying which of it was required. Worse, it framed setup as one step:
/// connecting Dropbox is only half of it, and nothing pushed anyone towards the
/// second half, so people finished the hard part and stopped.
///
/// So: one column, no sidebar, one decision per screen, an explicit "1 of 2",
/// and every escape hatch folded away behind a disclosure. It is shown once and
/// then never again.
enum WelcomeStep: Int, CaseIterable {
    case intro, connect, browser, ready

    /// Only the two middle screens are steps the user is being counted through.
    var stepNumber: Int? {
        switch self {
        case .connect: return 1
        case .browser: return 2
        default: return nil
        }
    }

    static let totalSteps = 2
}

/// Previews only.
///
/// Every screen here reads its truth from `Config`, `DefaultBrowser` and
/// `DropboxRoots` — which is right for the app and useless for looking at the
/// design, because on a Mac that already has Trace set up every screen renders
/// in its finished state. This pins a screen and the account/browser state it
/// should be drawn in, so the "not connected" and "not default" designs can
/// actually be seen without disconnecting anything.
struct WelcomePreview {
    var step: WelcomeStep
    var connected = false
    var isDefault = false
    var dropboxRunning = true
}

@MainActor
struct WelcomeView: View {
    /// Called when the flow is finished or skipped — the window closes and the
    /// flag is set, so this never appears again on its own.
    let onFinish: () -> Void

    /// Non-nil only from `#Preview`. Freezes the flow on one screen and stops
    /// the ticker pulling real system state back in underneath it.
    var preview: WelcomePreview? = nil

    @State private var step: WelcomeStep = .intro

    // Prerequisite
    @State private var dropboxAccounts = DropboxRoots.read()

    // Connect
    @State private var accountRole: String =
        DropboxRoots.read().contains { $0.isTeam } ? "work" : ""
    @State private var showAccountChoice = false
    @State private var pkce: PKCE?
    @State private var code = ""
    @State private var connecting = false
    @State private var connectError = ""
    @State private var connectWarning = ""
    @State private var accountLabel = Config.accountLabel
    @State private var appKey = Config.customAppKey

    // Browser
    @State private var browsers: [BrowserApp] = []
    @State private var selectedBrowser = Config.fallbackBrowserID ?? ""
    @State private var isDefault = DefaultBrowser.isCurrent
    @State private var makingDefault = false
    @State private var defaultError = ""
    @State private var needsMove = Installer.needsMove
    @State private var moving = false
    @State private var moveError = ""

    // Ready
    @State private var testLink = ""
    @State private var testing = false
    @State private var testPath: String?
    @State private var testDetail = ""
    @State private var testFailure: ResolveFailure?
    @State private var loginItemOn = LoginItem.isEnabled

    /// Slow on purpose. Its only jobs are noticing the default-browser binding
    /// landing and picking the authorisation code off the clipboard, neither of
    /// which needs to be instant.
    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var isConnected: Bool { accountLabel != nil }
    private var dropboxRunning: Bool { !dropboxAccounts.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .intro:   introStep
                    case .connect: connectStep
                    case .browser: browserStep
                    case .ready:   readyStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 20)
            }

            footer
        }
        .frame(width: 520, height: 600)
        .onAppear { resume() }
        .onReceive(ticker) { _ in tick() }
    }

    // MARK: - Intro

    /// Says what the app is before asking for anything, and checks the one
    /// prerequisite that makes every later step pointless if it's missing.
    private var introStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Trace")
                        .font(.largeTitle.bold())
                    Text("Click a Dropbox link, get the file in Finder.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Someone sends you a Dropbox link. You click it, and instead of a "
                 + "browser tab loading a preview, Finder opens with the file already "
                 + "selected. Everything that isn't a Dropbox link goes to your browser "
                 + "exactly as it did before.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Card {
                SettingRow(
                    "Dropbox desktop app",
                    description: dropboxRunning
                        ? dropboxAccounts
                            .map { ($0.root as NSString).lastPathComponent }
                            .joined(separator: ", ")
                        : "Not found. Trace opens files that are already synced to this "
                          + "Mac, so it needs the Dropbox app installed and running."
                ) {
                    if dropboxRunning {
                        StatusPill(text: "Syncing", tone: .good)
                    } else {
                        Button("Get Dropbox") {
                            Browser.open(URL(string: "https://www.dropbox.com/install")!)
                        }
                    }
                }
            }

            if !dropboxRunning {
                CalloutBox(
                    text: "You can carry on setting Trace up, but links won't resolve "
                        + "until Dropbox is syncing here.",
                    kind: .warning
                )
            }

            Text("Two things to set up. About a minute.")
                .font(.headline)
        }
    }

    // MARK: - Step 1 — Dropbox

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                "Connect your Dropbox",
                "Trace asks Dropbox where a link's file lives on your Mac. It gets "
                    + "read-only permission to look paths up, on your own account, and "
                    + "nothing else."
            )

            if isConnected {
                Card {
                    SettingRow("Connected", description: accountLabel ?? "") {
                        StatusPill(text: "Done", tone: .good)
                    }
                }
                if !connectWarning.isEmpty {
                    CalloutBox(text: connectWarning, kind: .warning)
                }
            } else if pkce != nil {
                // Authorisation is underway in the browser. One field, one
                // button, and nothing else to look at.
                VStack(alignment: .leading, spacing: 12) {
                    CalloutBox(
                        text: "Sign in as the account whose files you want to open, then "
                            + "approve. Dropbox shows you a code — copy it and it lands in "
                            + "the box below by itself.",
                        kind: .info
                    )
                    HStack {
                        TextField("Paste the code from Dropbox", text: $code)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") { finishAuthorisation() }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty
                                      || connecting)
                    }
                    if connecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…").foregroundStyle(.secondary)
                        }
                    }
                    Button("Start again") { pkce = nil; code = "" }
                        .buttonStyle(.link)
                }
            } else {
                Button("Connect Dropbox") { beginAuthorisation() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                accountChoice
            }

            if !connectError.isEmpty { CalloutBox(text: connectError, kind: .error) }

            if !isConnected { troubleDisclosure }
        }
    }

    /// The account-type question used to be the first thing a new user was
    /// asked — a three-way radio group above the button that actually does
    /// something. The default is already right (work, when a team Dropbox is
    /// synced here), so it states its guess in one quiet line and only becomes
    /// a control if the guess is wrong.
    private var accountChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(roleDescription)
                    .foregroundStyle(.secondary)
                Button(showAccountChoice ? "Hide" : "Change") {
                    withAnimation { showAccountChoice.toggle() }
                }
                .buttonStyle(.link)
            }
            .font(.callout)

            if showAccountChoice {
                Picker("", selection: $accountRole) {
                    Text("Work or team account").tag("work")
                    Text("Personal account").tag("personal")
                    Text("Whichever I'm signed in to").tag("")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }

    private var roleDescription: String {
        switch accountRole {
        case "work": return "Dropbox will ask for your work account."
        case "personal": return "Dropbox will ask for your personal account."
        default: return "Dropbox will use whichever account you're signed in to."
        }
    }

    /// Everything that used to compete with the primary button. "Sign out
    /// first" is an escape hatch, and a self-registered Dropbox app is for
    /// roughly nobody — neither belongs on the path a first-time user walks.
    private var troubleDisclosure: some View {
        DisclosureGroup("Having trouble?") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Hint("If Dropbox keeps offering the same account, it's reusing the "
                         + "session your browser already has. Sign out there first.")
                    Button("Sign out of Dropbox in the browser") {
                        Browser.open(DropboxAPI.logoutURL)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Hint("Trace uses its own Dropbox registration. To run it against one "
                         + "you created yourself, paste the app key here — it must be a "
                         + "Scoped app with Full Dropbox access and these three "
                         + "permissions.")
                    Text(DropboxError.requiredScopes.joined(separator: "   ·   "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        TextField("App key (optional)", text: $appKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Button("Dropbox app console") {
                            Browser.open(
                                URL(string: "https://www.dropbox.com/developers/apps")!
                            )
                        }
                    }
                    .onChange(of: appKey) {
                        Config.customAppKey = appKey.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            .padding(.top, 10)
        }
        .font(.callout)
    }

    // MARK: - Step 2 — Default browser

    /// The step the README says surprises people, and the one that previously
    /// got the least explanation at the moment of the decision. The reasoning
    /// goes above the button, and the fallback browser is chosen *before* the
    /// switch rather than discovered afterwards.
    private var browserStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                "Let Trace see your links",
                "macOS only hands a clicked link to the default browser, and there's no "
                    + "setting for \"just the Dropbox ones\". So Trace takes that slot, "
                    + "keeps the Dropbox links, and passes everything else straight "
                    + "through, untouched."
            )

            Card {
                SettingRow(
                    "Everything else opens in",
                    description: "Your real browser. Nothing about your browsing changes."
                ) {
                    Picker("", selection: $selectedBrowser) {
                        ForEach(browsers) { browser in
                            Text(browser.name).tag(browser.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: selectedBrowser) {
                        Config.fallbackBrowserID = selectedBrowser
                    }
                }
            }

            if needsMove && !isDefault {
                // Taking the slot from here would tie it to a path that won't
                // last, and `DefaultBrowser.request` refuses anyway — so offer
                // the move in place of a button that can only fail.
                CalloutBox(
                    text: "Trace is running from \(Installer.locationDescription). Move it to "
                        + "the Applications folder first. macOS records the default browser "
                        + "by location.",
                    kind: .warning
                )
                HStack(spacing: 10) {
                    Button("Move to Applications and Relaunch") {
                        moving = true
                        moveError = ""
                        Installer.installAndRelaunch { problem in
                            moveError = problem
                            moving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(moving)
                    if moving { ProgressView().controlSize(.small) }
                }
                if !moveError.isEmpty { CalloutBox(text: moveError, kind: .error) }
            } else if isDefault {
                Card {
                    SettingRow(
                        "Trace is handling links",
                        description: "Dropbox links open in Finder. Everything else goes "
                            + "to " + Browser.name(forBundleID: selectedBrowser) + "."
                    ) {
                        StatusPill(text: "Done", tone: .good)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button("Make Trace the default") { makeDefault() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(makingDefault)
                    if makingDefault { ProgressView().controlSize(.small) }
                }
                Hint("macOS will ask you to confirm. Trace also starts at login, since a "
                     + "link can only be handled while it's running.")
            }

            if !defaultError.isEmpty { CalloutBox(text: defaultError, kind: .error) }

            Hint("Changed your mind later? Settings → General → Give it back hands the "
                 + "slot straight back to your browser.")
        }
    }

    // MARK: - Ready

    /// Ends on a link actually resolving rather than on a tick. Someone who has
    /// watched Finder open once understands the app; someone looking at a green
    /// checkmark has only been told it works.
    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text("Ready")
                    .font(.largeTitle.bold())
            }

            Text("Try it now — paste any Dropbox link and Trace will show you where it "
                 + "lands.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("https://www.dropbox.com/scl/fi/…", text: $testLink)
                            .textFieldStyle(.roundedBorder)
                        Button("Test") { runTest() }
                            .disabled(testLink.trimmingCharacters(in: .whitespaces).isEmpty
                                      || testing)
                        Button("Paste") {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                testLink = pasted
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    if testing { ProgressView().controlSize(.small) }
                    if let testPath {
                        CalloutBox(text: "Found it — \(testDetail)\n\(testPath)", kind: .info)
                        Button("Show in Finder") { AppDelegate.present(testPath) }
                    }
                    if let testFailure {
                        CalloutBox(
                            text: testFailure.headline + "\n" + testFailure.detail,
                            kind: testFailure.symbol == "⚠" ? .warning : .error
                        )
                    }
                }
                .padding(15)
            }

            Card {
                SettingRow(
                    "Trace lives in the menu bar",
                    description: "No Dock icon and no window unless you open Settings. "
                        + "Click the pointer icon at the top of your screen for recent "
                        + "links and settings."
                ) {
                    Image(nsImage: MenuBarIcon.image(active: false, needsSetup: false))
                }
                CardDivider()
                SettingRow(
                    "Start at login",
                    description: "Links can only be handled while Trace is running."
                ) {
                    Toggle("", isOn: $loginItemOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: loginItemOn) {
                            _ = LoginItem.set(loginItemOn)
                            loginItemOn = LoginItem.isEnabled
                        }
                }
            }
        }
    }

    // MARK: - Chrome

    private func stepHeader(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let number = step.stepNumber {
                Text("STEP \(number) OF \(WelcomeStep.totalSteps)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
            }
            Text(title)
                .font(.largeTitle.bold())
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Back / progress / forward, pinned below the scroll view so the primary
    /// action never scrolls out of reach on a short window.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if step != .intro && step != .ready {
                    Button("Back") { back() }
                }

                Spacer(minLength: 0)

                progressDots

                Spacer(minLength: 0)

                if step == .ready {
                    Button("Done") { onFinish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip for now") { onFinish() }
                        .buttonStyle(.link)
                    Button(step == .intro ? "Get started" : "Continue") { advance() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdvance)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue
                          ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: step)
    }

    /// A step you haven't finished doesn't block you — "Skip for now" is right
    /// there, and a half-set-up app that says so is better than one that traps
    /// you. Continue is only disabled mid-authorisation, where advancing would
    /// discard a flow already in progress.
    private var canAdvance: Bool {
        !(step == .connect && pkce != nil && !isConnected)
    }

    // MARK: - Navigation

    /// Pick up wherever the user actually is. Someone who connected Dropbox and
    /// quit before taking the browser slot comes back to step 2, not step 1.
    private func resume() {
        loadBrowsers()

        if let preview {
            step = preview.step
            accountLabel = preview.connected ? "you@example.com" : nil
            isDefault = preview.isDefault
            dropboxAccounts = preview.dropboxRunning ? DropboxRoots.read() : []
            return
        }

        accountLabel = Config.accountLabel
        isDefault = DefaultBrowser.isCurrent
        dropboxAccounts = DropboxRoots.read()

        if isConnected && isDefault {
            step = .ready
        } else if isConnected {
            step = .browser
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.18)) {
            switch step {
            case .intro:   step = isConnected ? .browser : .connect
            case .connect: step = .browser
            case .browser: step = .ready
            case .ready:   onFinish()
            }
        }
    }

    private func back() {
        withAnimation(.easeInOut(duration: 0.18)) {
            switch step {
            case .browser: step = .connect
            case .connect: step = .intro
            default: break
            }
        }
    }

    private func tick() {
        // A preview's whole point is staying on the screen it was asked for.
        guard preview == nil else { return }

        autofillCodeFromClipboard()

        // The binding lands a second or two after macOS's confirmation sheet,
        // and can also be changed from System Settings while this is open.
        let wasDefault = isDefault
        isDefault = DefaultBrowser.isCurrent
        if isDefault != wasDefault { defaultError = "" }

        loginItemOn = LoginItem.isEnabled
        if !dropboxRunning { dropboxAccounts = DropboxRoots.read() }
    }

    // MARK: - Actions

    private func loadBrowsers() {
        browsers = Browser.installed()

        if selectedBrowser.isEmpty || !browsers.contains(where: { $0.id == selectedBrowser }) {
            if let captured = Config.fallbackBrowserID,
               browsers.contains(where: { $0.id == captured }) {
                selectedBrowser = captured
            } else if let guess = browsers.first(where: { $0.id == "com.apple.Safari" })
                        ?? browsers.first {
                selectedBrowser = guess.id
                Config.fallbackBrowserID = selectedBrowser
            }
        }
    }

    /// Dropbox shows the authorisation code on a web page to be copied. Once
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
                connectWarning = try await DropboxAPI.completeAuthorisation(
                    code: code,
                    verifier: pkce.verifier
                )
                accountLabel = Config.accountLabel
                self.pkce = nil
                code = ""
                // Straight on to step 2 — the old flow left you on a "Connected"
                // pill with nothing saying you were only halfway.
                if accountLabel != nil { advance() }
            } catch {
                connectError = DropboxError.friendly(error)
            }
            connecting = false
        }
    }

    private func makeDefault() {
        makingDefault = true
        defaultError = ""

        if !LoginItem.isEnabled {
            _ = LoginItem.set(true)
            loginItemOn = LoginItem.isEnabled
        }

        let before = DefaultBrowser.systemDefaultURL()?.path ?? "none"

        DefaultBrowser.request { problem in
            // Neither answer is evidence on its own: macOS shows its own
            // confirmation and the switch isn't instant, so silence isn't
            // success and a reported problem isn't failure. Wait, then look at
            // what actually happened.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let after = DefaultBrowser.systemDefaultURL()?.path ?? "none"
                isDefault = DefaultBrowser.isCurrent

                if isDefault {
                    advance()
                } else if let problem, !problem.isEmpty {
                    defaultError = "macOS refused: \(problem)"
                } else {
                    defaultError =
                        "macOS reported no error, but the handler is still \(after)"
                        + (before == after ? " (unchanged)." : " (was \(before)).")
                        + "\n\nIf no confirmation appeared, macOS declined silently. Open "
                        + "Settings → Advanced and run Repair, then set it in System "
                        + "Settings → Desktop & Dock → Default web browser."
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
            testFailure = ResolveFailure(headline: "That isn't a valid link.", detail: "")
            return
        }

        testing = true
        Task { @MainActor in
            let started = Date()
            let outcome = await LinkResolver.resolve(url)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            switch outcome {
            case .revealed(let path, let via, _):
                testPath = path
                testDetail = "\(via), \(elapsed) ms"
            case .failed(let failure):
                testFailure = failure
            }
            testing = false
        }
    }
}


// MARK: - Previews

/// One per screen, plus the two states that only exist before setup is done.
/// Open this file in Xcode and turn the canvas on (⌥⌘↩) to see them.

#Preview("1 · Intro") {
    WelcomeView(onFinish: {}, preview: WelcomePreview(step: .intro))
}

#Preview("1 · Intro — no Dropbox app") {
    WelcomeView(onFinish: {}, preview: WelcomePreview(step: .intro, dropboxRunning: false))
}

#Preview("2 · Connect Dropbox") {
    WelcomeView(onFinish: {}, preview: WelcomePreview(step: .connect))
}

#Preview("3 · Default browser") {
    WelcomeView(onFinish: {}, preview: WelcomePreview(step: .browser, connected: true))
}

#Preview("4 · Ready") {
    WelcomeView(
        onFinish: {},
        preview: WelcomePreview(step: .ready, connected: true, isDefault: true)
    )
}

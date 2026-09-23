import AppKit

// AppKit delivers every one of these callbacks on the main thread, but the
// delegate methods aren't declared main-actor-isolated, so touching NSApp or any
// @MainActor type from them is a compile error without this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var editingShortcutMonitor: Any?
    private var tokenTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — but set here rather than via LSUIElement in Info.plist,
        // because an Info.plist-declared agent app is not offered in the Default
        // web browser list. This gives the same result and stays eligible.
        //
        // Nothing may switch this back to `.regular`. The settings window used
        // to, which is what put an icon in the Dock for as long as it was open.
        NSApp.setActivationPolicy(.accessory)

        buildMainMenu()
        installEditingShortcutMonitor()

        // Something in AppKit's activation path promotes this app to `.regular`
        // — measured: the policy is already `.regular` on entry to
        // `applicationShouldHandleReopen`, before any of this app's window code
        // runs, and it can blip back at other moments too. The app can't stop
        // that happening, only undo it, so undo it every time it goes active.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }

        // Every Xcode build leaves another copy of this app registered with
        // LaunchServices as an https handler. Several copies claiming one bundle
        // id is what makes clicks go missing — macOS can route one to a build
        // folder that has since been deleted — and it hides the app from the
        // Default web browser list. Left alone it never heals, so heal it here.
        //
        // Deliberately deferred and off the main thread: this shells out to
        // lsregister, which takes seconds. When the app isn't already resident a
        // click launches it first, so anything slow here would sit directly
        // between the click and Finder opening.
        //
        // And only when this copy is new to LaunchServices — see
        // `DefaultBrowser.launchRepairDue` for what the unconditional version
        // cost on every login.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Only from an installed copy. `repair()` keeps the running copy
            // and unregisters every other one — run from Downloads or a build
            // folder, that would unregister the real install.
            guard !Installer.needsMove,
                  DefaultBrowser.launchRepairDue
            else { return }
            _ = await DefaultBrowser.repairAsync()
            DefaultBrowser.markLaunchRepairDone()
        }
        // Must happen before we ever become the default handler, or we'd record
        // ourselves as the browser to fall back to.
        Config.captureCurrentBrowserIfUnset()

        // Touching the shared instance starts Sparkle's scheduled checks. An app
        // distributed outside the App Store has nothing else keeping it current.
        _ = Updater.shared

        // Get the access token in hand before the first click needs it. Otherwise
        // the first link after every launch pays for a token refresh on top of
        // the lookup itself.
        if Config.isConfigured {
            Task {
                await TokenProvider.shared.prewarm()

                // `rootMatchScore == 0` is the app's own record that the local
                // folder was never verified against what Dropbox reports — the
                // state where every team link fails while the connection looks
                // healthy. It's detectable, so heal it rather than waiting for
                // someone to find the button. A folder picked by hand records a
                // score of 1, so this can't overwrite a deliberate choice.
                if Config.rootMatchScore == 0 {
                    _ = await DropboxAPI.repairRoot()
                }
            }
        }

        keepTokenWarm()

        // Only worth the ~110ms if links will actually be scripted into Safari.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard Config.openInNewTab,
                  (Config.fallbackBrowserID ?? SafariTab.bundleID) == SafariTab.bundleID
            else { return }
            SafariTab.prewarm()
        }

        // Start the badge's own state machine — it polls only while something
        // is outstanding, and stops for good once setup is complete.
        AppState.shared.refreshSetupState()

        // An install that predates the welcome flow has never written the flag,
        // so without this every existing user is shown a first-run window for
        // an app they finished setting up months ago. Being set up is itself
        // proof of having been through setup.
        if Config.isSetUp { Config.hasSeenWelcome = true }

        // A copy opened where it was downloaded has to move before anything
        // else is worth doing — everything set up from there is tied to a path
        // that won't last. Ask first, then carry on to the welcome flow if the
        // answer is "not now" or the move fails.
        if Installer.shouldOfferMoveAtLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.offerMove { self?.showWelcomeIfNeeded() }
            }
        } else {
            showWelcomeIfNeeded()
        }
    }

    /// First run gets the welcome flow, not the settings window. Opening
    /// Settings used to be the whole of onboarding: a six-item sidebar jumped to
    /// the Dropbox pane, no sense of how many steps there were, and nothing at
    /// all pushing anyone towards taking the browser slot afterwards.
    private func showWelcomeIfNeeded() {
        if !Config.hasSeenWelcome {
            WelcomeWindowController.shared.show()
        }
    }

    /// The standard "Move to Applications?" prompt. On success this process
    /// quits and the moved copy launches, so `otherwise` runs only when the
    /// app is staying where it is.
    private func offerMove(otherwise: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Move Trace to the Applications folder?"
        alert.informativeText = "Trace is running from \(Installer.locationDescription). "
            + "macOS records the default browser by location, so links stop reaching "
            + "Trace if this copy is moved or deleted, and updates cannot be installed here."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        NSApp.setActivationPolicy(.accessory)

        guard response == .alertFirstButtonReturn else {
            otherwise()
            return
        }
        Installer.installAndRelaunch { problem in
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Trace could not be moved"
            failure.informativeText = problem
            failure.runModal()
            otherwise()
        }
    }

    /// A refresh ahead of expiry, so no click waits on one — see
    /// `TokenProvider.prewarm`. Hourly, plus on wake: a timer doesn't run while
    /// the Mac sleeps, and waking is when a token has most likely lapsed. The
    /// short delay after wake lets the network come back first.
    private func keepTokenWarm() {
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            guard Config.isConfigured else { return }
            Task { await TokenProvider.shared.prewarm() }
        }
        tokenTimer?.tolerance = 300

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard Config.isConfigured else { return }
                await TokenProvider.shared.prewarm()
            }
        }
    }

    /// macOS delivers clicked http/https URLs here because Info.plist declares
    /// those schemes in CFBundleURLTypes.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    @objc func openSettings(_ sender: Any?) {
        SetupWindowController.shared.show()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    /// Clicking the app in Finder, Spotlight or Launchpad should open its
    /// settings. With no Dock icon and no window on screen, the default is to do
    /// nothing at all — which is indistinguishable from the app being broken.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        // Someone who has never finished setting up gets the guided flow rather
        // than being dropped into Settings to work out which panes matter.
        if !Config.hasSeenWelcome {
            WelcomeWindowController.shared.show()
        } else {
            SetupWindowController.shared.show()
        }
        return true
    }

    // MARK: - Editing shortcuts

    /// An accessory app never owns the menu bar, so AppKit doesn't route ⌘V, ⌘C,
    /// ⌘A and friends through `NSApp.mainMenu` on its behalf. The setup window
    /// asks you to paste an app key and an authorisation code, so those have to
    /// work — and the app can't buy them by becoming `.regular`, because that
    /// puts it in the Dock. Catch them here and send them down the responder
    /// chain by hand, which is all the menu would have done.
    private func installEditingShortcutMonitor() {
        editingShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command || modifiers == [.command, .shift] else { return event }
            guard let action = Self.editingAction(
                for: event.charactersIgnoringModifiers?.lowercased() ?? "",
                shift: modifiers.contains(.shift)
            ) else { return event }

            // Swallow the event only if something in the responder chain took it.
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    /// Selectors are written as strings because the Objective-C names are stable
    /// and unambiguous, and `#selector` would need a declaring type to hang off.
    private static func editingAction(for key: String, shift: Bool) -> Selector? {
        switch key {
        case "x": return Selector(("cut:"))
        case "c": return Selector(("copy:"))
        case "v": return Selector(("paste:"))
        case "a": return Selector(("selectAll:"))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        case "w": return Selector(("performClose:"))
        default: return nil
        }
    }

    // MARK: - Main menu

    /// A menu bar app has no menu of its own, and without one AppKit never
    /// delivers the standard editing shortcuts — ⌘V, ⌘C, ⌘A, ⌘Z all do nothing
    /// in a text field. The setup window asks you to paste an app key and an
    /// authorisation code, so that matters. Selectors are written as strings
    /// because the Objective-C names are stable and unambiguous.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Trace",
                        action: Selector(("orderFrontStandardAboutPanel:")),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdates(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(openSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Trace",
                        action: Selector(("hide:")),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Trace",
                        action: Selector(("terminate:")),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: Selector(("selectAll:")),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: Selector(("performClose:")),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimise",
                           action: Selector(("performMiniaturize:")),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Link handling

    /// Menu command: resolve whatever link is on the clipboard. Useful before the
    /// app is the default browser, and as a manual escape hatch afterwards.
    @MainActor
    static func handleClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            // The system beep is the whole of the feedback here now. It needs no
            // permission and it is what every other Mac app does when a command
            // has nothing to act on.
            NSSound.beep()
            return
        }
        (NSApp.delegate as? AppDelegate)?.handle(url)
    }

    @MainActor
    func handle(_ url: URL) {
        guard ShareLink.shouldIntercept(url) else {
            Browser.open(url)
            return
        }

        Task { @MainActor in
            AppState.shared.beganWorking()
            defer { AppState.shared.finishedWorking() }

            let started = Date()
            let outcome = await LinkResolver.resolve(url)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            switch outcome {
            case .revealed(let path, let via, let trace):
                Self.present(path)
                AppState.shared.record(
                    url: url,
                    headline: (path as NSString).lastPathComponent,
                    detail: "Found via \(via) in \(elapsed) ms"
                        + (trace.isEmpty ? "" : "\n\(trace)")
                        + "\n\(path)",
                    success: true,
                    path: path,
                    milliseconds: elapsed
                )

            case .failed(let failure):
                AppState.shared.record(
                    url: url,
                    headline: failure.headline,
                    detail: failure.detail
                        + "\n\n\(elapsed) ms total"
                        + (failure.trace.isEmpty ? "" : " — \(failure.trace)"),
                    success: false,
                    symbol: failure.symbol,
                    milliseconds: elapsed
                )
                // No notification: the browser tab opening is itself the
                // feedback, and the menu bar list carries the reason for anyone
                // who wants it. A Mac that syncs little of its Dropbox would
                // otherwise be banner-ed on nearly every click.
                Browser.open(url)
            }
        }
    }

    /// Show the user the file the link pointed at, however they asked to be
    /// shown it. Opening a folder in Finder is the same gesture either way, so
    /// "open" only differs for an actual file.
    @MainActor
    static func present(_ path: String) {
        let url = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard Config.revealBehaviour == .open, !isDirectory.boolValue else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct BrowserApp: Identifiable, Hashable {
    let id: String      // bundle identifier — stable, unlike the path
    let name: String
    let url: URL
}

enum Browser {
    /// Hands a URL to the browser the user picked in Settings.
    static func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()

        if let id = Config.fallbackBrowserID,
           // Never hand a link back to ourselves — that would loop forever.
           id != Bundle.main.bundleIdentifier,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            if Config.openInNewTab, SafariTab.open(url, bundleID: id) { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return
        }

        // Nothing usable configured — Safari is on every Mac, so the click is
        // never simply lost.
        if let safari = safari() {
            if Config.openInNewTab,
               SafariTab.open(url, bundleID: SafariTab.bundleID) { return }
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration)
            return
        }

        // Both routes gone, and `NSWorkspace.open(url)` is not the answer — we
        // are the default handler, so it would come straight back to us and
        // loop. The click has nowhere to go, so at least don't swallow it in
        // silence; the browser is chosen in Settings → General.
        NSSound.beep()
    }

    static func safari() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
    }

    /// Every app that can handle a web URL, minus this one, de-duplicated by
    /// bundle id (the same browser can be reported at more than one path).
    static func installed() -> [BrowserApp] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let me = Bundle.main.bundleIdentifier

        var seen = Set<String>()
        var result: [BrowserApp] = []

        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let identifier = Bundle(url: appURL)?.bundleIdentifier,
                  identifier != me,
                  !seen.contains(identifier)
            else { continue }
            seen.insert(identifier)
            result.append(BrowserApp(id: identifier, name: name(of: appURL), url: appURL))
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func name(of app: URL) -> String {
        (app.lastPathComponent as NSString).deletingPathExtension
    }

    static func name(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return id }
        return name(of: url)
    }
}

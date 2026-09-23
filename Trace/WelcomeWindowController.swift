import AppKit
import SwiftUI

/// Hosts `WelcomeView` in its own window.
///
/// Kept apart from `SetupWindowController` on purpose. That window is a
/// Music-style split view with a full-height vibrant sidebar and a tracking
/// separator in the toolbar — the right shape for settings, and exactly the
/// wrong shape for a first run, where the sidebar is the thing getting in the
/// way. This is a plain fixed-size sheet-like window with nothing in it but the
/// step you're on.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(onFinish: { [weak self] in
                self?.finish()
            }))
            // Same reason as the settings window: an NSHostingController reports
            // its content's ideal size as a preferred content size, and the
            // window grows to satisfy it on a later layout pass, quietly
            // overruling `setContentSize`. The view sets its own fixed frame.
            host.sizingOptions = []

            let created = NSWindow(contentViewController: host)
            created.title = ""
            // Not resizable. Every screen here is a fixed amount of prose and
            // one control; there is nothing to gain by dragging it about, and a
            // resizable window invites someone to make the first thing they ever
            // see look broken.
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setContentSize(NSSize(width: 520, height: 600))
            created.center()
            window = created
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Something in the activation path promotes this app from `.accessory`
        // to `.regular`, which puts an icon in the Dock — see the same dance in
        // SetupWindowController. Undo it, then re-key the window, because
        // setting the policy can drop focus.
        NSApp.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Finished or skipped. Either way this doesn't open itself again — the
    /// menu bar carries the reminder from here on, and Settings is always
    /// there. Nagging someone who chose "Skip for now" with the same window
    /// every launch is how an app gets quit for good.
    private func finish() {
        Config.hasSeenWelcome = true
        AppState.shared.refreshSetupState()
        window?.close()
    }

    /// Closing with the red button counts as skipping, for the same reason.
    ///
    /// The window is released rather than kept: see
    /// `SetupWindowController.windowWillClose` — a kept window's 1.5s ticker
    /// would otherwise go on firing for the life of the app, long after the
    /// first run it exists for.
    func windowWillClose(_ notification: Notification) {
        Config.hasSeenWelcome = true
        AppState.shared.refreshSetupState()
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            // Reopened in the meantime — that window is in use again.
            guard let self, let closing, self.window === closing, !closing.isVisible
            else { return }
            closing.contentViewController = nil
            self.window = nil
        }
    }
}

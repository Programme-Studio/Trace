import AppKit
import SwiftUI


/// A plain AppKit window hosting the SwiftUI setup view. Managed by hand so that
/// a background app doesn't pop a window open every launch.
@MainActor
final class SetupWindowController: NSObject {
    static let shared = SetupWindowController()

    private var window: NSWindow?

    /// Set once the user has moved or resized the window; after that macOS
    /// restores their position and this class stops centring it.
    private static let frameAutosaveName = "TraceSettingsWindow"

    func show() {
        if window == nil {
            let split = SettingsSplitViewController()
            let created = NSWindow(contentViewController: split)
            // Deliberately empty. With the title bar hidden there is nowhere for
            // a title to go, and an empty one keeps it out of the window menu
            // and Mission Control label too.
            created.title = ""

            // No title bar of its own — the sidebar runs the full height of the
            // window and the traffic lights float over it, the way Music, Mail
            // and System Settings do. `fullSizeContentView` lets the content
            // extend up behind the title bar; the other two stop the title bar
            // drawing a background or a title over the top of it.
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                                 .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            // With no title bar to grab, the whole background becomes the handle.
            created.isMovableByWindowBackground = true

            // The toolbar is built by the split view controller, because it
            // needs to hand AppKit a tracking separator bound to `splitView` —
            // see `SettingsSplitViewController.makeToolbar()`. A unified
            // toolbar with no such item is enough to switch the window into
            // unified mode, but not enough to tell AppKit where the
            // sidebar/detail boundary actually is inside that band — that's
            // what caused the padding chase this replaces.
            created.toolbar = split.makeToolbar()
            created.toolbarStyle = .unified
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName(Self.frameAutosaveName)
            window = created

            // Centring has to wait for layout. `NSWindow(contentViewController:)`
            // sizes itself to the hosted view, and the split view settles its
            // size on a later pass — so centring inline centred the window at
            // its pre-layout size, and it then grew from its bottom-left origin
            // (macOS windows are anchored bottom-left), which is why it opened
            // high and to the right. Centre once now so it never flashes in the
            // corner, then again once the size is final.
            if !created.setFrameUsingName(Self.frameAutosaveName) {
                // Only the first time. Wide enough for the sidebar plus a detail
                // column that reads comfortably, and no wider — this is a
                // settings window, not a document. Once the user has sized it
                // themselves, that size is restored above and this never runs
                // again.
                created.setContentSize(NSSize(width: 680, height: 540))
                created.center()
                DispatchQueue.main.async { [weak created] in created?.center() }
            }
        }

        // Stay an accessory app. This used to switch to `.regular` so the window
        // would get a menu bar — an accessory app doesn't own one, and the setup
        // steps need ⌘V and ⌘A in their text fields. But `.regular` is precisely
        // what puts an icon in the Dock, and it stayed there for as long as the
        // window was open. AppDelegate's key monitor handles those shortcuts
        // instead, so the window can be a first-class window without the app
        // pretending to be a first-class app.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Then put it straight back. Something in the activation path promotes
        // this app from `.accessory` to `.regular` — and it is not this class:
        // measured with a file probe, the policy is already `.regular` on entry
        // to `applicationShouldHandleReopen`, before any window code here has
        // run. Whether that's AppKit's reopen handling or SwiftUI's, the app
        // can't stop it happening, only undo it. Re-ordering the window calls
        // around this: `activate` is what leaves the app frontmost, and setting
        // the policy afterwards can drop key focus, so the window is re-keyed.
        NSApp.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
    }
}

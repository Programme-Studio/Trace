import SwiftUI

@main
struct TraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            // The icon is the only feedback a Slack click gets before Finder
            // opens, so it fills in solid while a link is being looked up.
            Image(nsImage: MenuBarIcon.image(active: state.isWorking))
        }
    }
}

enum MenuBarIcon {
    /// The menu bar glyph is an SF Symbol rather than the hand-drawn 18pt PNGs
    /// this used to ship.
    ///
    /// Apple's own symbols are optically corrected per size and weight and
    /// aligned to the menu bar's cap height, which hand-drawn line art at 18px
    /// almost never is — it reads a touch heavy or a touch high next to every
    /// other icon in the bar. Using the system set also means the icon tracks
    /// the menu bar's size and the user's accessibility weight for free.
    ///
    /// `shippingbox` for the name; it fills in solid while a link is being
    /// looked up, which is the only feedback a click from Slack gets before
    /// Finder opens.
    ///
    /// Note this is fine for UI but must NOT be done for the *app* icon — the
    /// SF Symbols licence specifically forbids symbols in app icons and logos,
    /// which is why `make_icons.py` still draws that one.
    static func image(active: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(
            systemSymbolName: active ? "shippingbox.fill" : "shippingbox",
            accessibilityDescription: "Trace"
        )?.withSymbolConfiguration(configuration)

        // Template so macOS inverts it for light and dark menu bars itself.
        symbol?.isTemplate = true
        return symbol ?? NSImage()
    }
}

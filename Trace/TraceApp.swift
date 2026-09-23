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
            // opens, so it thickens while a link is being looked up — and
            // carries a dot for as long as setup is unfinished, which is the
            // one signal a user sees without opening anything.
            Image(nsImage: MenuBarIcon.image(
                active: state.isWorking,
                needsSetup: !state.isSetUp
            ))
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
    /// `pointer.arrow.ipad.rays` for the name. It has no `.fill` counterpart,
    /// so the "looking a link up" state — the only feedback a click from Slack
    /// gets before Finder opens — is a heavier stroke rather than a solid fill.
    ///
    /// Note this is fine for UI but must NOT be done for the *app* icon — the
    /// SF Symbols licence specifically forbids symbols in app icons and logos,
    /// which is why `make_icons.py` still draws that one.
    /// `needsSetup` adds an attention dot in the top-right corner. A template
    /// image is a mask — every opaque pixel is painted in the menu bar's own
    /// colour — so a plain filled dot would merge into the glyph beneath it. It
    /// is punched out with a slightly larger `.clear` disc first, which leaves a
    /// gap in the mask and reads as a ring of menu bar showing through, however
    /// the bar is tinted.
    static func image(active: Bool, needsSetup: Bool = false) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: active ? .bold : .regular
        )
        guard let symbol = NSImage(
            systemSymbolName: "pointer.arrow.ipad.rays",
            accessibilityDescription: "Trace"
        )?.withSymbolConfiguration(configuration) else { return NSImage() }

        // Mirrored horizontally. The symbol ships pointing up-left, the way a
        // macOS cursor does, but the app icon's own cursor points up-right —
        // and two pointers aiming opposite ways across one app reads as an
        // oversight rather than a choice. The menu bar defers to the icon.
        //
        // A drawing-handler image is re-run at whatever size and scale the bar
        // asks for, so this stays crisp on any display; what it gives up is
        // the symbol's live tracking of weight, which the configuration above
        // has already pinned anyway.
        let mirrored = NSImage(size: symbol.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // Only the glyph is mirrored. The badge is drawn after the state is
            // restored, so "top right" stays top right rather than following the
            // flip over to the left.
            context.saveGState()
            context.translateBy(x: rect.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            symbol.draw(in: rect)
            context.restoreGState()

            guard needsSetup else { return true }

            let radius: CGFloat = 2.6
            let centre = CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
            let dot = CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )

            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -1.1, dy: -1.1))
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: dot)
            return true
        }

        // Template so macOS inverts it for light and dark menu bars itself.
        mirrored.isTemplate = true
        mirrored.accessibilityDescription = "Trace"
        return mirrored
    }
}

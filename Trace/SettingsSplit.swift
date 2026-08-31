import AppKit
import SwiftUI

// MARK: - Panes

/// The sidebar. Order is deliberate: what the app is doing, then the things
/// worth changing, then the things you only open when something is wrong.
enum SettingsPane: String, CaseIterable, Identifiable {
    case status, general, dropbox, activity, advanced, about
    var id: Self { self }

    /// The panes above the gap. `about` sits on its own at the bottom, the
    /// way Music and System Settings park their identity item.
    static var main: [SettingsPane] { allCases.filter { $0 != .about } }

    var title: String {
        switch self {
        case .status:   return "Status"
        case .general:  return "General"
        case .dropbox:  return "Dropbox"
        case .activity: return "Activity"
        case .advanced: return "Advanced"
        case .about:    return "Trace"
        }
    }

    /// Outline symbols throughout — several of these have no `.fill` variant,
    /// so the row stays consistent by not filling any of them. The pointer on
    /// About is the same glyph as the menu bar, so Settings names the app with
    /// the icon the user already clicks.
    var symbol: String {
        switch self {
        case .status:   return "antenna.radiowaves.left.and.right"
        case .general:  return "compass.drawing"
        case .dropbox:  return "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .activity: return "waveform.badge.magnifyingglass"
        case .advanced: return "sharedwithyou"
        case .about:    return "pointer.arrow.ipad.rays"
        }
    }

    /// Only About carries the pointer, and only the pointer is mirrored, so
    /// it faces the same way as the cursor in the app icon beside it.
    var mirrored: Bool { self == .about }

    var tint: Color {
        switch self {
        case .status:   return .green
        case .general:  return .gray
        case .dropbox:  return .blue
        case .activity: return .orange
        case .advanced: return .red
        case .about:    return .traceBrown
        }
    }
}

extension Color {
    /// The app icon's own background. `icon.json` states it as
    /// `display-p3:0.52941,0.43529,0.30588` — the same numbers as #876F4E —
    /// so it is declared in Display P3 here too, and the About tile is the
    /// exact brown of the icon it sits next to rather than an sRGB near-miss.
    static let traceBrown = Color(
        .displayP3,
        red: 0.52941,
        green: 0.43529,
        blue: 0.30588
    )
}

// MARK: - Shared selection

/// The selected pane, shared by the two halves of the split view. They are
/// separate hosting controllers, so this can't be `@State` in either one.
@Observable
@MainActor
final class SettingsModel {
    var pane: SettingsPane = .status
}

// MARK: - Split view

/// The settings window's split view, built in AppKit rather than with SwiftUI's
/// `NavigationSplitView`.
///
/// `NSSplitViewItem(sidebarWithViewController:)` is the system preset for a
/// Music-style sidebar: AppKit gives it full-height vibrancy, runs it up behind
/// the title bar, and puts the traffic lights on it. A `NavigationSplitView`
/// hosted inside our own `NSWindow` did not get that treatment — it drew the
/// sidebar as an inset rounded panel starting *below* the title bar, leaving the
/// traffic lights sitting on a bare strip above it. Two attempts to fix that
/// from the SwiftUI side (a hand-rolled `NSVisualEffectView`, then reverting to
/// a plain `List`) both missed the point: the behaviour comes from the split
/// view *item*, which SwiftUI wasn't being allowed to own.
@MainActor
final class SettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    let model = SettingsModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        // `sizingOptions = []` on both halves is what makes the window's own
        // size stick. An NSHostingController defaults to reporting its SwiftUI
        // content's ideal size as a preferred content size, and
        // `NSWindow(contentViewController:)` grows the window to satisfy it on a
        // later layout pass — so `setContentSize` was being quietly overruled and
        // the window opened at whatever the content felt like, measured at
        // 700×586 against a requested 680×540. The split items' thicknesses still
        // set the minimum width; nothing else needs to.
        let sidebarHost = NSHostingController(rootView: SettingsSidebar(model: model))
        sidebarHost.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        // Enough for the icon and "Advanced", the longest label, and no more.
        sidebar.minimumThickness = 172
        sidebar.maximumThickness = 240
        sidebar.canCollapse = false
        addSplitViewItem(sidebar)

        let detailHost = NSHostingController(rootView: SetupView(model: model))
        detailHost.sizingOptions = []
        let detail = NSSplitViewItem(viewController: detailHost)
        // The two thicknesses set the window's minimum width between them, so a
        // generous floor here is a window that cannot be made small. Descriptions
        // wrap to a second line below roughly this, which is a fair trade for
        // being able to tuck the window into a corner.
        detail.minimumThickness = 420
        addSplitViewItem(detail)
    }

    // MARK: - Toolbar

    /// The real fix for full-height sidebar layout, found in Apple's own docs
    /// after two rounds of hand-computed padding both made things worse.
    ///
    /// A `NSToolbar` with no items and no delegate — what this had before —
    /// is enough to switch the window into unified-toolbar mode, but it is
    /// NOT what actually tells AppKit where the sidebar/detail boundary sits
    /// inside that toolbar band. That's the job of a real toolbar item:
    /// `.sidebarTrackingSeparator`, backed by an `NSTrackingSeparatorToolbarItem`
    /// bound to this split view's own divider. Apple's docs describe it
    /// plainly: it's what lets AppKit "place the separator inside the title
    /// bar and make the full height bar effective." Every app that gets this
    /// layout right — Mail, Notes, Music — uses this, not manual insets.
    ///
    /// With it wired up, AppKit positions both panes' content correctly on
    /// its own. The `detailTopInset`/`safeAreaInsets` guesswork this replaced
    /// is gone entirely — there is nothing left to compensate for by hand.
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TraceSettingsToolbar")
        toolbar.delegate = self
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .sidebarTrackingSeparator else { return nil }
        return NSTrackingSeparatorToolbarItem(
            identifier: .sidebarTrackingSeparator,
            splitView: splitView,
            dividerIndex: 0
        )
    }

}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List(selection: $model.pane) {
            ForEach(SettingsPane.main) { item in
                row(item)
            }
        }
        .listStyle(.sidebar)
        // The vibrancy belongs to the split view item; the list must not paint
        // its own background over it.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { aboutRow }
    }

    private func row(_ item: SettingsPane) -> some View {
        Label {
            Text(item.title)
        } icon: {
            SidebarIcon(symbol: item.symbol, tint: item.tint, mirrored: item.mirrored)
        }
        .padding(.vertical, 2)
        .tag(item)
    }

    /// Pinned to the floor of the sidebar, so styled by hand — it sits outside
    /// the list and gets none of its selection chrome.
    private var aboutRow: some View {
        let selected = model.pane == .about
        return Button {
            model.pane = .about
        } label: {
            HStack(spacing: 6) {
                SidebarIcon(
                    symbol: SettingsPane.about.symbol,
                    tint: SettingsPane.about.tint,
                    mirrored: SettingsPane.about.mirrored
                )
                Text(SettingsPane.about.title)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

import AppKit
import Foundation
import Observation

struct LogEntry: Identifiable {
    /// Built once when the entry is recorded. `timeText` used to construct a
    /// `DateFormatter` on every access — which, being a menu row, meant one per
    /// row per redraw, and DateFormatter is famously expensive to create.
    @MainActor fileprivate static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    let id = UUID()
    let date: Date
    /// Pre-formatted at creation; see `timeFormatter`.
    let timeText: String
    let link: String
    let headline: String
    let detail: String
    let success: Bool
    let resolvedPath: String?
    /// ✓ worked, ⚠ expected-but-couldn't (not synced, offline), ✗ genuine failure.
    let symbol: String
    /// How long the whole lookup took. Shown in the menu, because "it feels slow"
    /// is much easier to act on with a number attached.
    let milliseconds: Int?

    var durationText: String {
        guard let milliseconds else { return "" }
        return milliseconds < 1000
            ? "\(milliseconds)ms"
            : String(format: "%.1fs", Double(milliseconds) / 1000)
    }

    /// The headline cut down for the menu bar.
    ///
    /// A menu is as wide as its widest row, so one long filename drags the whole
    /// thing across the screen. Truncated in the *middle*, not the end: these
    /// names routinely differ only in a suffix — `…_ST13_260828.pdf` against
    /// `…_ST13_V2_260828.pdf` — and tail truncation would render two different
    /// files as the same row. Keeping both ends also keeps the extension visible.
    ///
    /// Wrapping the name over two lines was tried instead and does not work:
    /// `MenuBarExtra` in its default `.menu` style is a real `NSMenu`, and a
    /// menu item renders a single line whatever the string contains. A tooltip
    /// via `.help()` does reach `NSMenuItem.toolTip`, but macOS draws it
    /// detached from the menu in system styling, which was rejected on looks.
    /// Anything richer needs `.menuBarExtraStyle(.window)` and a hand-built menu.
    var menuHeadline: String { LogEntry.truncatedMiddle(headline, to: LogEntry.menuNameLimit) }

    /// Roughly the width of "Open Link from Clipboard" plus its shortcut, so the
    /// history rows never become the widest thing in the menu.
    static let menuNameLimit = 44

    static func truncatedMiddle(_ text: String, to limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let keep = limit - 1
        let tail = keep / 2
        return text.prefix(keep - tail) + "…" + text.suffix(tail)
    }

    /// SF Symbol matching `symbol`, for the menu bar's icon-led rows.
    var statusSymbolName: String {
        switch symbol {
        case "✓": return "checkmark.circle.fill"
        case "⚠": return "exclamationmark.triangle.fill"
        default:  return "xmark.circle.fill"
        }
    }

}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    /// True while *any* link is being resolved, so the menu bar icon can show
    /// it. A counter rather than a flag: two links clicked close together used
    /// to have the first one to finish clear the icon while the second was still
    /// running.
    private(set) var isWorking = false
    private var inFlight = 0

    func beganWorking() {
        inFlight += 1
        isWorking = true
    }

    func finishedWorking() {
        inFlight = max(0, inFlight - 1)
        isWorking = inFlight > 0
    }
    private(set) var entries: [LogEntry] = []

    /// Set when the user clicks a failed link in the menu: the setup window picks
    /// it up and drops it into the test field, so "why didn't that work?" is one
    /// click away from a full explanation.
    var pendingTestLink: String?

    func record(
        url: URL,
        headline: String,
        detail: String = "",
        success: Bool,
        symbol: String? = nil,
        path: String? = nil,
        milliseconds: Int? = nil
    ) {
        guard Config.keepHistory else { return }

        entries.insert(
            LogEntry(
                date: Date(),
                timeText: LogEntry.timeFormatter.string(from: Date()),
                link: url.absoluteString,
                headline: headline,
                detail: detail,
                success: success,
                resolvedPath: path,
                symbol: symbol ?? (success ? "✓" : "✗"),
                milliseconds: milliseconds
            ),
            at: 0
        )
        if entries.count > 25 { entries.removeLast(entries.count - 25) }
    }

    func clearHistory() { entries.removeAll() }

    /// Is this app currently the system's default handler for web links?
    var isDefaultBrowser: Bool { DefaultBrowser.isCurrent }
}

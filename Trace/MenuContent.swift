import AppKit
import SwiftUI

struct MenuContent: View {
    private let state = AppState.shared

    /// The menu speaks up only when something needs doing. A standing
    /// "Connected: <email>" row told you nothing you didn't already know on
    /// every open, and was the widest thing here after the history rows.
    private var warnings: [String] {
        var warnings: [String] = []
        if Config.accountLabel == nil {
            warnings.append("Not set up yet")
        }
        if Config.isConfigured && !state.isDefaultBrowser {
            warnings.append("Not your default browser")
        }
        return warnings
    }

    var body: some View {
        ForEach(warnings, id: \.self) { warning in
            Text(warning)
        }
        // Conditional, or an empty status section leaves the menu opening on a
        // separator.
        if !warnings.isEmpty {
            Divider()
        }

        Button {
            AppDelegate.handleClipboard()
        } label: {
            Label("Open Link from Clipboard", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("v")

        Divider()

        if state.entries.isEmpty {
            Text("No links opened yet")
        } else {
            ForEach(state.entries.prefix(8)) { entry in
                Button {
                    if let path = entry.resolvedPath {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    } else {
                        // Hand the link to the test field so the window can
                        // explain what happened rather than just opening blank.
                        AppState.shared.pendingTestLink = entry.link
                        SetupWindowController.shared.show()
                    }
                } label: {
                    Label(
                        "\(entry.timeText)  \(entry.menuHeadline)  ·  \(entry.durationText)",
                        systemImage: entry.statusSymbolName
                    )
                }
            }
        }

        Divider()

        Button {
            Updater.shared.checkForUpdates()
        } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
            SetupWindowController.shared.show()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Trace", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}

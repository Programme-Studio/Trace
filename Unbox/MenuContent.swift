import AppKit
import SwiftUI

struct MenuContent: View {
    private let state = AppState.shared

    var body: some View {
        if let account = Config.accountLabel {
            Text("Connected: \(account)")
        } else {
            Text("Not set up yet")
        }
        if Config.isConfigured && !state.isDefaultBrowser {
            Text("Not your default browser")
        }

        Divider()

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
                        "\(entry.timeText)  \(entry.headline)  ·  \(entry.durationText)",
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
            Label("Quit Unbox", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}

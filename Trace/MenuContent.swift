import AppKit
import SwiftUI

struct MenuContent: View {
    private let state = AppState.shared

    /// Something outstanding, and what to do about it.
    ///
    /// These used to be plain `Text` rows — "Not set up yet" stated a problem
    /// and offered nothing to press, which is the worst of both: it tells you
    /// the app is broken and leaves you to go and find the fix. They're buttons
    /// now, and each one opens the flow at the step it's complaining about.
    private struct Warning: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let action: () -> Void
    }

    /// The menu speaks up only when something needs doing. A standing
    /// "Connected: <email>" row told you nothing you didn't already know on
    /// every open, and was the widest thing here after the history rows.
    private var warnings: [Warning] {
        var warnings: [Warning] = []

        if Config.accountLabel == nil {
            warnings.append(Warning(
                id: "connect",
                title: "Finish setting up Trace…",
                symbol: "exclamationmark.circle.fill",
                action: { WelcomeWindowController.shared.show() }
            ))
        } else if !state.isDefaultBrowser {
            // Only once connected, and only one at a time: the welcome flow
            // resumes at whichever step is outstanding, so two rows pointing at
            // the same window would just be noise.
            warnings.append(Warning(
                id: "default",
                title: "Make Trace your default browser…",
                symbol: "exclamationmark.circle.fill",
                action: { WelcomeWindowController.shared.show() }
            ))
        }

        return warnings
    }

    var body: some View {
        ForEach(warnings) { warning in
            Button(action: warning.action) {
                Label(warning.title, systemImage: warning.symbol)
            }
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

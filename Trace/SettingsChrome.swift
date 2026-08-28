import SwiftUI

/// The visual vocabulary of a System Settings pane: a sidebar of tinted icons,
/// and a detail column of grouped cards whose rows are
/// title / description / trailing control.
///
/// The point of the shape is that a row's *state* always sits in the same place
/// — hard right, same baseline as the title — so the pane can be read down that
/// edge alone to find the one thing that needs attention.

// MARK: - Sidebar

/// A tinted rounded-square glyph, the sidebar idiom macOS uses for settings.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Cards

/// A grouped card. Rows inside are separated with `CardDivider`, inset to line
/// up under the text rather than cutting the full width.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 15)
    }
}

/// One row of a card: a title, an optional explanation under it, and whatever
/// control or status belongs on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var description: String?
    var dimmed = false
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        description: String? = nil,
        dimmed: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.dimmed = dimmed
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(_ title: String, description: String? = nil, dimmed: Bool = false) {
        self.init(title, description: description, dimmed: dimmed) { EmptyView() }
    }
}

/// A read-only state capsule — the "Granted" / "Downloaded" idiom. Not a button,
/// and shaped so it doesn't read as one.
struct StatusPill: View {
    enum Tone { case good, attention, neutral }

    let text: String
    var tone: Tone = .neutral

    private var foreground: Color {
        switch tone {
        case .good: return .green
        case .attention: return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .fixedSize()
    }
}

/// The banner at the top of a pane — a green tick and a sentence, or an amber
/// one when something needs doing.
struct PaneBanner: View {
    let ok: Bool
    let title: String
    let message: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill"
                                         : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.orange)
                    Text(title).font(.headline)
                }
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }
}

/// Small muted explanatory line.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

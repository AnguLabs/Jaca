import SwiftUI
import Lemonade

/// A single monospaced log line. Presentational only — selection + copy are handled
/// by the list so multiple lines can be selected and copied at once.
struct LogRowView: View {
    let line: LogLine
    var isSelected: Bool = false

    /// A violet not used by any log level, so death/restart/reconnect events pop.
    private static let markerColor = Color(red: 0.62, green: 0.45, blue: 1.0)

    var body: some View {
        if line.isMarker {
            markerRow
        } else {
            logRow
        }
    }

    /// Section-divider style with padding above/below, so the event is unmissable.
    private var markerRow: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Self.markerColor.opacity(0.45)).frame(height: 1)
            Text(line.message)
                .font(LogLevelStyle.mono(11).weight(.semibold))
                .foregroundStyle(Self.markerColor)
                .fixedSize()
            Rectangle().fill(Self.markerColor.opacity(0.45)).frame(height: 1)
        }
        .padding(.vertical, 12)
    }

    private var logRow: some View {
        HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing200) {
            Text(line.timestamp.logClock)
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 92, alignment: .leading)

            Text(line.level.short)
                .fontWeight(.bold)
                .foregroundStyle(LogLevelStyle.color(for: line.level))
                .frame(width: 16, alignment: .center)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LogLevelStyle.badgeBackground(for: line.level))
                )

            // Always reserve the tag column (even when empty) so the message column
            // stays aligned and doesn't jump between tagged and untagged lines.
            Text(line.tag.isEmpty ? "" : tagLabel)
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 168, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(line.tag)

            Text(line.message)
                .foregroundStyle(LogLevelStyle.color(for: line.level))
                // Only the selected row is text-selectable, so a plain click reliably
                // selects the row first; then you can drag-select a word within it.
                .textSelectable(isSelected)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LogLevelStyle.mono())
        .padding(.vertical, 1)
        .background(isSelected
            ? LemonadeTheme.colors.interaction.bgSubtleInteractive
            : Color.clear)
    }

    private var tagLabel: String {
        line.pid > 0 ? "\(line.tag) (\(line.pid))" : line.tag
    }
}

private extension View {
    /// `.textSelection(.enabled/.disabled)` can't be a ternary (distinct types).
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { self.textSelection(.enabled) } else { self.textSelection(.disabled) }
    }
}

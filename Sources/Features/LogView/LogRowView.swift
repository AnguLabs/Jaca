import SwiftUI
import Lemonade
import AppKit

/// A single monospaced log line. Kept lightweight — rendered inside a virtualized
/// list under high throughput.
struct LogRowView: View {
    let line: LogLine

    var body: some View {
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

            if !line.tag.isEmpty {
                Text(tagLabel)
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .frame(width: 168, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(line.message)
                .foregroundStyle(LogLevelStyle.color(for: line.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LogLevelStyle.mono())
        .padding(.vertical, 1)
        .contextMenu {
            Button("Copy Line") { copy(line.raw) }
            Button("Copy Message") { copy(line.message) }
        }
    }

    private var tagLabel: String {
        line.pid > 0 ? "\(line.tag) (\(line.pid))" : line.tag
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

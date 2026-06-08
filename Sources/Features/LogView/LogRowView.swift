import SwiftUI
import Lemonade

/// A single monospaced log line. Presentational only — selection + copy are handled
/// by the list so multiple lines can be selected and copied at once.
struct LogRowView: View {
    let line: LogLine
    var isSelected: Bool = false

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
                .textSelection(.enabled)   // drag within a line to select/copy a word or part
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

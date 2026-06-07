import SwiftUI
import Lemonade

/// Maps log severity to Lemonade semantic colors and provides the monospaced
/// face used throughout the log view (logs want a fixed-width font).
enum LogLevelStyle {
    static func color(for level: LogLevel) -> Color {
        let c = LemonadeTheme.colors.content
        switch level {
        case .verbose: return c.contentTertiary
        case .debug:   return c.contentSecondary
        case .info:    return c.contentPrimary
        case .warn:    return c.contentCaution
        case .error:   return c.contentCritical
        case .fatal:   return c.contentCritical
        }
    }

    /// Subtle background tint for the level glyph badge.
    static func badgeBackground(for level: LogLevel) -> Color {
        let bg = LemonadeTheme.colors.background
        switch level {
        case .verbose, .debug: return bg.bgNeutralSubtle
        case .info:            return bg.bgInfoSubtle
        case .warn:            return bg.bgCautionSubtle
        case .error, .fatal:   return bg.bgCriticalSubtle
        }
    }

    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Date {
    /// `HH:mm:ss.SSS` used in the log time column.
    var logClock: String {
        Self.clockFormatter.string(from: self)
    }
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

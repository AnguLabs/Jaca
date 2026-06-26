import SwiftUI
import Lemonade

/// Maps Cloud Logging severity to Lemonade semantic colors (mirrors `LogLevelStyle`).
enum CloudSeverityStyle {
    static func color(for severity: CloudSeverity) -> Color {
        let c = LemonadeTheme.colors.content
        switch severity {
        case .default:   return c.contentTertiary
        case .debug:     return c.contentSecondary
        case .info:      return c.contentPrimary
        case .notice:    return c.contentInfo
        case .warning:   return c.contentCaution
        case .error, .critical, .alert, .emergency: return c.contentCritical
        }
    }

    /// Subtle background tint for the severity glyph badge.
    static func badgeBackground(for severity: CloudSeverity) -> Color {
        let bg = LemonadeTheme.colors.background
        switch severity {
        case .default, .debug:  return bg.bgNeutralSubtle
        case .info, .notice:    return bg.bgInfoSubtle
        case .warning:          return bg.bgCautionSubtle
        case .error, .critical, .alert, .emergency: return bg.bgCriticalSubtle
        }
    }
}

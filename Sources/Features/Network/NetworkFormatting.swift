import SwiftUI
import Lemonade

/// Shared formatting for the network inspector.
enum NetworkFormatting {
    static func statusColor(_ txn: NetworkTransaction) -> Color {
        let c = LemonadeTheme.colors.content
        if txn.error != nil { return c.contentCritical }
        guard let code = txn.statusCode else { return c.contentTertiary }
        switch code {
        case 200..<300: return c.contentPositive
        case 300..<400: return c.contentInfo
        case 400..<500: return c.contentCaution
        default: return c.contentCritical
        }
    }

    static func size(_ bytes: Int) -> String {
        if bytes <= 0 { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
        return String(format: "%.2f s", seconds)
    }

    /// Renders a body for display: pretty-prints JSON, shows text as-is, or
    /// summarizes binary content.
    static func bodyText(_ data: Data?, contentType: String?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let type = (contentType ?? "").lowercased()
        if type.contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "<\(size(data.count)) binary data>"
    }
}

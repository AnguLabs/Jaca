import Foundation
import Network

/// Tiny HTTP server for QR-code onboarding: it hosts the Jaca mobile APK and a landing
/// page. The phone scans the QR, opens this page, and downloads the APK from the Mac. The
/// act of fetching reveals the phone's LAN IP (onClientSeen), so the desktop can then
/// auto-connect to the companion app once it's running.
final class CompanionWebServer {
    private let apkURL: URL?
    private let queue = DispatchQueue(label: "dev.srsouza.jaca.web")
    private var listener: NWListener?
    /// Called with the phone's LAN IP each time it hits the server.
    var onClientSeen: ((String) -> Void)?
    private(set) var port: UInt16 = 0

    init(apkURL: URL?) {
        self.apkURL = apkURL
    }

    @discardableResult
    func start(port preferred: UInt16 = 8890) -> UInt16? {
        let params = NWParameters.tcp
        let listener: NWListener
        if let p = NWEndpoint.Port(rawValue: preferred), let l = try? NWListener(using: params, on: p) {
            listener = l; port = preferred
        } else if let l = try? NWListener(using: params) {
            listener = l
        } else {
            return nil
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = listener.port { self?.port = p.rawValue }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
        return port == 0 ? nil : port
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let ip = Self.remoteIP(conn) { self?.onClientSeen?(ip) }
                self?.receive(conn)
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self?.respond(conn, path: Self.path(from: request))
        }
    }

    private func respond(_ conn: NWConnection, path: String) {
        let body: Data
        let contentType: String
        var filename: String?
        if path.hasPrefix("/jaca.apk"), let apkURL, let apk = try? Data(contentsOf: apkURL) {
            body = apk; contentType = "application/vnd.android.package-archive"; filename = "jaca.apk"
        } else {
            body = Data(Self.landingHTML.utf8); contentType = "text/html; charset=utf-8"
        }
        var header = "HTTP/1.0 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        if let filename { header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n" }
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func path(from request: String) -> String {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first ?? ""
        let parts = firstLine.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    private static func remoteIP(_ conn: NWConnection) -> String? {
        guard case let .hostPort(host, _) = conn.endpoint else { return nil }
        var s = "\(host)"
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // strip %en0 zone
        return s
    }

    private static let landingHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Jaca</title><style>body{font-family:-apple-system,system-ui,sans-serif;max-width:520px;margin:48px auto;padding:0 20px;color:#1c1c1e}
    a.btn{display:inline-block;background:#D9E021;color:#1c1c1e;text-decoration:none;font-weight:700;padding:14px 22px;border-radius:12px;margin-top:16px}
    p{line-height:1.5}</style></head><body>
    <h1>Install Jaca</h1>
    <p>Download the Jaca companion app, open it, and start capture. Your desktop connects
    automatically, and the app sets up HTTPS decryption for you — nothing else to download.</p>
    <a class="btn" href="/jaca.apk">Download Jaca.apk</a>
    <p style="color:#8e8e93;margin-top:24px;font-size:14px">You may need to allow installs from this browser.</p>
    </body></html>
    """
}

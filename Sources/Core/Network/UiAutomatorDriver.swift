import Foundation

/// Minimal UIAutomator driver over `adb`: dumps the on-screen view hierarchy,
/// finds nodes by visible text / resource-id, taps them, scrolls, and waits for
/// screens. Pure `adb` (no on-device app), like the rest of Jaca's device tooling.
///
/// Powers the optional **Auto** install mode: it walks a non-rooted device through
/// the system "Install CA certificate" flow, pausing at the biometric/PIN gate
/// (which only the user can pass). Inherently OEM/locale-dependent, so matching
/// uses candidate-string lists (English + the device's language) and stable
/// resource-ids where they exist.
final class UiAutomatorDriver: @unchecked Sendable {
    struct Node: Equatable {
        let text: String
        let resourceId: String
        let desc: String
        let bounds: CGRect
        var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    private let adbURL: URL
    private let serial: String
    private let dumpPath = "/sdcard/jaca-ui.xml"

    init(adbURL: URL, serial: String) {
        self.adbURL = adbURL
        self.serial = serial
    }

    // MARK: - Reading the screen

    /// Dumps and parses the current view hierarchy. Returns nil when the dump is
    /// empty — e.g. a `FLAG_SECURE` screen, or mid-transition.
    func dump() async -> [Node]? {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "uiautomator", "dump", dumpPath])
        guard let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "cat", dumpPath]),
              r.stdout.contains("<node") else { return nil }
        return Self.parse(r.stdout)
    }

    func foregroundActivity() async -> String {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "dumpsys", "activity", "activities"])
        return r?.stdout ?? ""
    }

    // MARK: - Acting

    func tap(_ node: Node) async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "input", "tap",
                                                  "\(Int(node.center.x))", "\(Int(node.center.y))"])
    }

    func scrollDown() async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "input", "swipe",
                                                  "540", "1800", "540", "600", "300"])
    }

    func openSecuritySettings() async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "start",
                                                  "-a", "android.settings.SECURITY_SETTINGS"])
    }

    /// Dumps, finds a node matching any candidate (scrolling down up to `scrolls`
    /// times to reveal it), and taps it. Returns whether it tapped.
    @discardableResult
    func tapText(_ candidates: [String], scrolls: Int = 5) async -> Bool {
        for attempt in 0...scrolls {
            if let nodes = await dump(), let node = Self.find(text: candidates, in: nodes) {
                await tap(node)
                return true
            }
            if attempt < scrolls { await scrollDown(); try? await Task.sleep(for: .milliseconds(450)) }
        }
        return false
    }

    /// Taps a node by exact resource-id (locale-independent), if present.
    @discardableResult
    func tapId(_ id: String) async -> Bool {
        guard let nodes = await dump(), let node = Self.find(id: id, in: nodes) else { return false }
        await tap(node)
        return true
    }

    /// Polls until any candidate text or the given resource-id appears on screen.
    func waitFor(text candidates: [String] = [], id: String? = nil, timeoutSeconds: Int) async -> Bool {
        for _ in 0..<timeoutSeconds {
            if Task.isCancelled { return false }
            if let nodes = await dump() {
                if !candidates.isEmpty, Self.find(text: candidates, in: nodes) != nil { return true }
                if let id, Self.find(id: id, in: nodes) != nil { return true }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Parsing (pure & testable)

    static func find(text candidates: [String], in nodes: [Node]) -> Node? {
        for candidate in candidates {
            let needle = candidate.lowercased()
            if let n = nodes.first(where: {
                $0.text.lowercased().contains(needle) || $0.desc.lowercased().contains(needle)
            }) { return n }
        }
        return nil
    }

    static func find(id: String, in nodes: [Node]) -> Node? {
        nodes.first { $0.resourceId == id }
    }

    static func parse(_ xml: String) -> [Node] {
        var nodes: [Node] = []
        let ns = xml as NSString
        guard let nodeRx = try? NSRegularExpression(pattern: "<node\\b[^>]*?/?>") else { return [] }
        for m in nodeRx.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let text = attribute("text", in: tag)
            let rid = attribute("resource-id", in: tag)
            let desc = attribute("content-desc", in: tag)
            if text.isEmpty && rid.isEmpty && desc.isEmpty { continue }
            nodes.append(Node(text: text, resourceId: rid, desc: desc,
                              bounds: parseBounds(attribute("bounds", in: tag))))
        }
        return nodes
    }

    private static func attribute(_ name: String, in tag: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: "\(name)=\"([^\"]*)\"") else { return "" }
        let ns = tag as NSString
        guard let m = rx.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return "" }
        return ns.substring(with: m.range(at: 1))
    }

    static func parseBounds(_ s: String) -> CGRect {
        let nums = s.split(whereSeparator: { !($0.isNumber) }).compactMap { Int($0) }
        guard nums.count == 4 else { return .zero }
        return CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
    }
}

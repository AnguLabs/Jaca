import SwiftUI

// MARK: - Glyphs

enum GroveGlyph { case branch, folder, eraser, unlink }

/// Custom Lucide-style glyphs the Lemonade icon set doesn't provide.
/// Each glyph is authored on a 24×24 grid (Lucide convention) and scaled to `size`.
/// Strokes use ~1.8pt at 24px, round caps/joins.
struct GroveIcon: View {
    let glyph: GroveGlyph
    var size: CGFloat = 17
    var tint: Color = .white

    private var lineWidth: CGFloat { 1.8 }

    var body: some View {
        Canvas { context, _ in
            switch glyph {
            case .branch:
                strokeBranch(in: context)
            case .folder:
                let p = SVGPath.parse("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z")
                context.stroke(p, with: .color(tint), style: strokeStyle)
            case .eraser:
                var p = SVGPath.parse("m7 21 -4.3-4.3 c-1-1 -1-2.5 0-3.4 l9.6-9.6 c1-1 2.5-1 3.4 0 l5.6 5.6 c1 1 1 2.5 0 3.4 L13 21")
                p.addPath(SVGPath.parse("M22 21 H7"))
                p.addPath(SVGPath.parse("m5 11 9 9"))
                context.stroke(p, with: .color(tint), style: strokeStyle)
            case .unlink:
                var p = SVGPath.parse("m18.84 12.25 1.72-1.71 a5.004 5.004 0 0 0 -.12-7.07 5.006 5.006 0 0 0 -6.95 0 l-1.72 1.71")
                p.addPath(SVGPath.parse("m5.17 11.75 -1.71 1.71 a5.004 5.004 0 0 0 .12 7.07 5.006 5.006 0 0 0 6.95 0 l1.71-1.71"))
                p.move(to: CGPoint(x: 8, y: 2));  p.addLine(to: CGPoint(x: 8, y: 5))
                p.move(to: CGPoint(x: 2, y: 8));  p.addLine(to: CGPoint(x: 5, y: 8))
                p.move(to: CGPoint(x: 16, y: 19)); p.addLine(to: CGPoint(x: 16, y: 22))
                p.move(to: CGPoint(x: 19, y: 16)); p.addLine(to: CGPoint(x: 22, y: 16))
                context.stroke(p, with: .color(tint), style: strokeStyle)
            }
        }
        .frame(width: 24, height: 24)
        .scaleEffect(size / 24, anchor: .center)
        .frame(width: size, height: size)
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    private func strokeBranch(in context: GraphicsContext) {
        var p = Path()
        // vertical line (6,3) -> (6,15)
        p.move(to: CGPoint(x: 6, y: 3))
        p.addLine(to: CGPoint(x: 6, y: 15))
        // circles r=3
        p.addEllipse(in: CGRect(x: 18 - 3, y: 6 - 3, width: 6, height: 6))
        p.addEllipse(in: CGRect(x: 6 - 3, y: 18 - 3, width: 6, height: 6))
        // quarter arc (18,9) -> (9,18), radius 9, center (9,9), sweeping clockwise
        p.move(to: CGPoint(x: 18, y: 9))
        // In SwiftUI's default coordinate space (y-down), clockwise visually = counterclockwise param.
        // Arc from angle 0 (right of center -> point (18,9)) to angle 90° (below center -> point (9,18)).
        p.addArc(center: CGPoint(x: 9, y: 9), radius: 9,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        context.stroke(p, with: .color(tint), style: strokeStyle)
    }
}

// MARK: - Minimal SVG path parser (M/m L/l H/h V/v C/c A/a Z)

private enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero

        let raw = tokenizeWithCommands(d)
        var i = 0
        func nextNum() -> CGFloat {
            guard i < raw.count, case let .number(v) = raw[i] else { return 0 }
            i += 1
            return CGFloat(v)
        }
        func nextPoint(relative: Bool) -> CGPoint {
            let x = nextNum(), y = nextNum()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while i < raw.count {
            guard case let .command(c) = raw[i] else { i += 1; continue }
            i += 1
            let rel = c.isLowercase
            switch Character(c.lowercased()) {
            case "m":
                current = nextPoint(relative: rel)
                path.move(to: current)
                start = current
                // subsequent coordinate pairs are implicit lineto
                while i < raw.count, case .number = raw[i] {
                    current = nextPoint(relative: rel)
                    path.addLine(to: current)
                }
            case "l":
                while i < raw.count, case .number = raw[i] {
                    current = nextPoint(relative: rel)
                    path.addLine(to: current)
                }
            case "h":
                while i < raw.count, case .number = raw[i] {
                    let x = nextNum()
                    current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
            case "v":
                while i < raw.count, case .number = raw[i] {
                    let y = nextNum()
                    current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                    path.addLine(to: current)
                }
            case "c":
                while i < raw.count, case .number = raw[i] {
                    let c1 = nextPoint(relative: rel)
                    let c2 = nextPoint(relative: rel)
                    let end = nextPoint(relative: rel)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                }
            case "a":
                while i < raw.count, case .number = raw[i] {
                    let rx = nextNum(), ry = nextNum()
                    let xAxisRotation = nextNum()
                    let largeArc = nextNum() != 0
                    let sweep = nextNum() != 0
                    let end = nextPoint(relative: rel)
                    addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                           xAxisRotation: xAxisRotation, largeArc: largeArc, sweep: sweep)
                    current = end
                }
            case "z":
                path.closeSubpath()
                current = start
            default:
                break
            }
        }
        return path
    }

    private enum Token { case command(Character); case number(Double) }

    private static func tokenizeWithCommands(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var numBuf = ""
        func flush() {
            if !numBuf.isEmpty, let v = Double(numBuf) { tokens.append(.number(v)) }
            numBuf = ""
        }
        let cmds = Set("MmLlHhVvCcSsQqTtAaZz")
        let chars = Array(d)
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if cmds.contains(ch) {
                flush()
                tokens.append(.command(ch))
                idx += 1
            } else if ch == "-" {
                // minus starts a new number unless it's an exponent sign
                if !numBuf.isEmpty, let last = numBuf.last, last == "e" || last == "E" {
                    numBuf.append(ch)
                } else {
                    flush()
                    numBuf.append(ch)
                }
                idx += 1
            } else if ch == "." {
                // a second '.' starts a new number
                if numBuf.contains(".") { flush() }
                numBuf.append(ch)
                idx += 1
            } else if ch.isNumber || ch == "e" || ch == "E" {
                numBuf.append(ch)
                idx += 1
            } else {
                // whitespace or comma -> separator
                flush()
                idx += 1
            }
        }
        flush()
        return tokens
    }

    /// Endpoint-parameterization SVG arc -> center, converted into a Path arc.
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat,
                               xAxisRotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Correct out-of-range radii
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(num / den)
        if largeArc == sweep { coef = -coef }

        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                               (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        // Approximate the elliptical arc with cubic bezier segments.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        let t = (4.0 / 3.0) * tan(delta / 4)

        var angleStart = theta1
        for _ in 0..<segments {
            let angleEnd = angleStart + delta
            let cosA1 = cos(angleStart), sinA1 = sin(angleStart)
            let cosA2 = cos(angleEnd), sinA2 = sin(angleEnd)

            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                let x = cosPhi * rx * ex - sinPhi * ry * ey + cx
                let y = sinPhi * rx * ex + cosPhi * ry * ey + cy
                return CGPoint(x: x, y: y)
            }

            let endPt = map(cosA2, sinA2)
            let c1 = map(cosA1 - t * sinA1, sinA1 + t * cosA1)
            let c2 = map(cosA2 + t * sinA2, sinA2 - t * cosA2)
            path.addCurve(to: endPt, control1: c1, control2: c2)
            angleStart = angleEnd
        }
    }
}

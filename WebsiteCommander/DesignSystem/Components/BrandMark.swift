import SwiftUI

/// Official provider brand marks, rendered as true vector `Shape`s.
///
/// TRADEMARK NOTICE: each mark is the property of its owner and is used here
/// strictly for *nominative identification* — shown unmodified, monochrome, at
/// correct proportions, beside the provider's name, to indicate which service an
/// option connects to (per OpenAI's brand guidelines and equivalent fair-use
/// practice for the others). They are never used as this app's own branding,
/// never recolored into a logo, and never shown more prominently than the app's
/// own mark. The vector geometry is the CC0 vectorization from Simple Icons
/// (the trademarks themselves remain the owners'); the xAI mark is reconstructed
/// geometrically as it is not in that set.
enum BrandMarkID: String {
    case openai, anthropic, gemini, deepseek, mistral, copilot, xai

    /// Map a provider id (as used in `ProviderRegistry`) to its brand mark.
    static func from(providerID: String) -> BrandMarkID? {
        switch providerID {
        case "openai": return .openai
        case "anthropic": return .anthropic
        case "gemini": return .gemini
        case "deepseek": return .deepseek
        case "mistral": return .mistral
        case "copilot": return .copilot
        case "grok": return .xai
        default: return nil
        }
    }

    var officialPath: String {
        switch self {
        case .openai:
            return "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
        case .anthropic:
            return "M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"
        case .gemini:
            return "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
        case .deepseek:
            return "M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45"
        case .mistral:
            return "M17.143 3.429v3.428h-3.429v3.429h-3.428V6.857H6.857V3.43H3.43v13.714H0v3.428h10.286v-3.428H6.857v-3.429h3.429v3.429h3.429v-3.429h3.428v3.429h-3.428v3.428H24v-3.428h-3.43V3.429z"
        case .copilot:
            return "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"
        case .xai:
            return "M5.13 2.87 L2.87 5.13 L18.87 21.13 L21.13 18.87 Z M21.13 5.13 L18.87 2.87 L2.87 18.87 L5.13 21.13 Z"
        }
    }
}

// MARK: - SVG path parser (subset: M L H V C S Q T A Z, abs + rel)
// Internal (not private) so the unit-test target can verify the parser against
// the official brand paths.

enum SVGOp {
    case move(CGPoint), line(CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case quad(CGPoint, CGPoint)
    case close
}

struct SVGParser {
    let s: [Character]
    var i = 0
    var cur = CGPoint.zero
    var start = CGPoint.zero
    var lastCtrl = CGPoint.zero
    var lastCmd: Character = " "

    init(_ str: String) { self.s = Array(str) }

    mutating func skipWS() {
        while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\t" || s[i] == "," { i += 1 }
    }
    mutating func peek() -> Character? { i < s.count ? s[i] : nil }
    mutating func moreNums() -> Bool {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "\n" || s[j] == "\t" || s[j] == "," { j += 1 }
        guard j < s.count else { return false }
        let c = s[j]
        if c.isLetter { return false }
        return c == "-" || c == "+" || c == "." || c.isNumber
    }
    mutating func num() -> Double {
        skipWS()
        var str = ""
        if let c = peek(), c == "-" || c == "+" { str.append(c); i += 1 }
        var dot = false
        while i < s.count {
            let c = s[i]
            if c.isNumber { str.append(c); i += 1 }
            else if c == ".", !dot { dot = true; str.append(c); i += 1 }
            else if c == "e" || c == "E" {
                str.append(c); i += 1
                if let n = peek(), n == "+" || n == "-" { str.append(n); i += 1 }
            } else { break }
        }
        return Double(str) ?? 0
    }
    mutating func flag() -> Double {
        skipWS()
        guard i < s.count, s[i] == "0" || s[i] == "1" else { return 0 }
        let v = s[i] == "1" ? 1.0 : 0.0; i += 1; return v
    }

    mutating func parse() -> [SVGOp] {
        var ops: [SVGOp] = []
        var cmd: Character = " "
        while i < s.count {
            skipWS()
            if let c = peek(), c.isLetter { cmd = c; i += 1 }
            let rel = "mlhvcsqta".contains(cmd)
            let up = Character(String(cmd).uppercased())
            switch up {
            case "M":
                var p = pt(num(), num(), rel: rel); ops.append(.move(p)); cur = p; start = p; lastCtrl = p
                while moreNums() { p = pt(num(), num(), rel: rel); ops.append(.line(p)); cur = p; lastCtrl = p }
            case "L":
                repeat { let p = pt(num(), num(), rel: rel); ops.append(.line(p)); cur = p; lastCtrl = p } while moreNums()
            case "H":
                repeat { let x = num(); let p = rel ? CGPoint(x: cur.x + x, y: cur.y) : CGPoint(x: x, y: cur.y); ops.append(.line(p)); cur = p; lastCtrl = p } while moreNums()
            case "V":
                repeat { let y = num(); let p = rel ? CGPoint(x: cur.x, y: cur.y + y) : CGPoint(x: cur.x, y: y); ops.append(.line(p)); cur = p; lastCtrl = p } while moreNums()
            case "C":
                repeat {
                    let x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num()
                    let c1 = pt(x1, y1, rel: rel), c2 = pt(x2, y2, rel: rel), p = pt(x, y, rel: rel)
                    ops.append(.cubic(c1, c2, p)); lastCtrl = c2; cur = p
                } while moreNums()
            case "S":
                repeat {
                    let refl = (lastCmd == "C" || lastCmd == "S") ? CGPoint(x: 2*cur.x - lastCtrl.x, y: 2*cur.y - lastCtrl.y) : cur
                    let x2 = num(), y2 = num(), x = num(), y = num()
                    let c2 = pt(x2, y2, rel: rel), p = pt(x, y, rel: rel)
                    ops.append(.cubic(refl, c2, p)); lastCtrl = c2; cur = p
                } while moreNums()
            case "Q":
                repeat {
                    let x1 = num(), y1 = num(), x = num(), y = num()
                    let c1 = pt(x1, y1, rel: rel), p = pt(x, y, rel: rel)
                    ops.append(.quad(c1, p)); lastCtrl = c1; cur = p
                } while moreNums()
            case "T":
                repeat {
                    let refl = (lastCmd == "Q" || lastCmd == "T") ? CGPoint(x: 2*cur.x - lastCtrl.x, y: 2*cur.y - lastCtrl.y) : cur
                    let p = pt(num(), num(), rel: rel)
                    ops.append(.quad(refl, p)); lastCtrl = refl; cur = p
                } while moreNums()
            case "A":
                repeat {
                    let rx = num(), ry = num(), rot = num()
                    let la = flag(), sw = flag()
                    let p = pt(num(), num(), rel: rel)
                    for seg in arcs(from: cur, to: p, rx: rx, ry: ry, phi: rot, large: la > 0.5, sweep: sw > 0.5) {
                        ops.append(.cubic(seg.0, seg.1, seg.2))
                    }
                    lastCtrl = cur; cur = p
                } while moreNums()
            case "Z":
                ops.append(.close); cur = start; lastCtrl = cur
            default: break
            }
            lastCmd = up
            skipWS()
        }
        return ops
    }

    private mutating func pt(_ x: Double, _ y: Double, rel: Bool) -> CGPoint {
        rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
    }
}

func arcs(from p1: CGPoint, to p2: CGPoint, rx inRx: Double, ry inRy: Double,
                  phi deg: Double, large: Bool, sweep: Bool) -> [(CGPoint, CGPoint, CGPoint)] {
    var rx = inRx, ry = inRy
    // A zero-length arc (identical endpoints) has no curve; return a degenerate
    // segment instead of dividing by zero below, which would produce NaN and
    // trap in Int(ceil(NaN)).
    if p1.x == p2.x && p1.y == p2.y { return [(p1, p2, p2)] }
    let phi = deg * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    if rx == 0 || ry == 0 { return [(p1, p2, p2)] }
    rx = abs(rx); ry = abs(ry)
    var lam = (x1p*x1p)/(rx*rx) + (y1p*y1p)/(ry*ry)
    if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s; lam = 1 }
    var sq = (rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p) / (rx*rx*y1p*y1p + ry*ry*x1p*x1p)
    if sq < 0 { sq = 0 }
    let coef = sqrt(sq) * (large == sweep ? -1 : 1)
    let cxp = coef * (rx * y1p / ry)
    let cyp = coef * -(ry * x1p / rx)
    let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x)/2
    let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y)/2
    func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let n = sqrt(ux*ux+uy*uy) * sqrt(vx*vx+vy*vy)
        if n == 0 { return 0 }
        var c = (ux*vx+uy*vy)/n; c = max(-1, min(1, c))
        var a = acos(c)
        if ux*vy - uy*vx < 0 { a = -a }
        return a
    }
    let theta1 = ang(1, 0, (x1p-cxp)/rx, (y1p-cyp)/ry)
    var dtheta = ang((x1p-cxp)/rx, (y1p-cyp)/ry, (-x1p-cxp)/rx, (-y1p-cyp)/ry)
    if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
    if sweep, dtheta < 0 { dtheta += 2 * .pi }
    let segs = max(1, Int(ceil(abs(dtheta) / (.pi/2))))
    let delta = dtheta / Double(segs)
    let t = 8.0/3.0 * sin(delta/4) * sin(delta/4) / sin(delta/2)
    var out: [(CGPoint, CGPoint, CGPoint)] = []
    var th = theta1
    func mapPt(_ a: Double, _ b: Double) -> CGPoint {
        CGPoint(x: cosPhi*a - sinPhi*b + cx, y: sinPhi*a + cosPhi*b + cy)
    }
    for _ in 0..<segs {
        let cos1 = cos(th), sin1 = sin(th), cos2 = cos(th+delta), sin2 = sin(th+delta)
        let c1 = mapPt(rx*(cos1 - t*sin1), ry*(sin1 + t*cos1))
        let c2 = mapPt(rx*(cos2 + t*sin2), ry*(sin2 - t*cos2))
        let p2c = mapPt(rx*cos2, ry*sin2)
        out.append((c1, c2, p2c))
        th += delta
    }
    return out
}

// MARK: - The shape

/// A vector brand mark drawn from its official SVG path, fitted (contain) into
/// the given rect. Render it in a single color (`.primary` adapts to light/dark).
struct BrandMark: Shape {
    let id: BrandMarkID

    /// Parsed geometry for each mark, computed once. `path(in:)` runs on every
    /// layout pass of every rendered mark, so re-parsing the SVG string each
    /// time is pure waste. The ops are value types, so sharing is safe.
    private static let cachedOps: [BrandMarkID: [SVGOp]] = {
        var dict: [BrandMarkID: [SVGOp]] = [:]
        for id: BrandMarkID in [.openai, .anthropic, .gemini, .deepseek, .mistral, .copilot, .xai] {
            var parser = SVGParser(id.officialPath)
            dict[id] = parser.parse()
        }
        return dict
    }()

    func path(in rect: CGRect) -> Path {
        let ops = Self.cachedOps[id] ?? []
        // The official marks are authored on a 24×24 viewBox.
        let sx = rect.width / 24, sy = rect.height / 24
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * sx, y: rect.minY + p.y * sy) }
        var path = Path()
        for op in ops {
            switch op {
            case .move(let p): path.move(to: t(p))
            case .line(let p): path.addLine(to: t(p))
            case .cubic(let a, let b, let c): path.addCurve(to: t(c), control1: t(a), control2: t(b))
            case .quad(let a, let b):
                let cur = path.currentPoint ?? .zero
                let c1 = CGPoint(x: cur.x + 2/3*(t(a).x-cur.x), y: cur.y + 2/3*(t(a).y-cur.y))
                let c2 = CGPoint(x: t(b).x + 2/3*(t(a).x-t(b).x), y: t(b).y + 2/3*(t(a).y-t(b).y))
                path.addCurve(to: t(b), control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

// MARK: - Brand tile (mirrors IconTile but draws the real mark)

/// A rounded, tinted tile holding the official brand mark in monochrome — the
/// compliant way to show a provider's logo (single surface color, unmodified).
struct BrandTile: View {
    let id: BrandMarkID
    var tint: Color = .primary
    var size: CGFloat = 40
    var filled: Bool = false

    var body: some View {
        BrandMark(id: id)
            .fill(filled ? Color.white : tint)
            .padding(size * 0.24)
            .frame(width: size, height: size)
            .background(
                (filled ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(tint.opacity(0.14))),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

/// Convenience: a brand tile when a mark exists, else an SF Symbol tile.
@MainActor
@ViewBuilder
func ProviderTile(providerID: String, tint: Color = .primary, size: CGFloat = 40, filled: Bool = false) -> some View {
    if let mark = BrandMarkID.from(providerID: providerID) {
        BrandTile(id: mark, tint: tint, size: size, filled: filled)
    } else {
        IconTile(systemImage: ProviderRegistry.info(for: providerID)?.icon ?? "cpu.fill",
                 tint: tint, size: size, gradient: filled)
    }
}

import SwiftUI
import UIKit

/// Brand tokens, taken from the naturMesh site (index.html `:root`).
/// Colours live in Assets.xcassets under the site's own names; the site is dark-only and so is the app.
enum Brand {
    static let name = "naturMesh"
    static let tagline = "The network that survives the weather."

    // Palette
    static let moss = Color("Moss")        // #0A130F deepest background
    static let canopy = Color("Canopy")    // #132019 page background
    static let bark = Color("Bark")        // #1D2C23 raised surfaces
    static let birch = Color("Birch")      // #F4F2EA text
    static let lichen = Color("Lichen")    // #B9CBB4 secondary text, rules
    static let signal = Color("Signal")    // #7FE3A1 accent, live, mesh
    static let ember = Color("Ember")      // #E8663C urgent, SOS

    static let rule = Color("Lichen").opacity(0.18)
    static let corner: CGFloat = 12

    // Typefaces: Fraunces (display) and Archivo (text), both bundled under the SIL OFL.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        custom(["Fraunces-SemiBold", "Fraunces-9ptSemiBold", "Fraunces"], size: size, fallback: .serif, weight: weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Archivo-Bold"
        case .semibold: name = "Archivo-SemiBold"
        case .medium: name = "Archivo-Medium"
        default: name = "Archivo-Regular"
        }
        return custom([name, "Archivo"], size: size, fallback: .default, weight: weight)
    }

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    private static func custom(_ names: [String], size: CGFloat, fallback: Font.Design, weight: Font.Weight) -> Font {
        for n in names where UIFont(name: n, size: size) != nil {
            return Font.custom(n, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: fallback)
    }
}

/// The site's mark: leaf venation drawn as a node-link graph. The veins are the network.
struct LeafMark: View {
    var size: CGFloat = 30
    var tint: Color = Brand.signal
    var tip: Color = Brand.birch

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width / 34, sz.height / 38)
            let ox = (sz.width - 34 * s) / 2, oy = (sz.height - 38 * s) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            var stem = Path(); stem.move(to: p(17, 37)); stem.addLine(to: p(17, 4))
            ctx.stroke(stem, with: .color(tint), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))

            var outline = Path()
            outline.move(to: p(17, 4))
            outline.addCurve(to: p(3, 19), control1: p(17, 4), control2: p(3, 9))
            outline.addCurve(to: p(17, 30), control1: p(3, 26), control2: p(10, 30))
            outline.addCurve(to: p(31, 19), control1: p(24, 30), control2: p(31, 26))
            outline.addCurve(to: p(17, 4), control1: p(31, 9), control2: p(17, 4))
            ctx.stroke(outline, with: .color(tint.opacity(0.45)), lineWidth: 1.4 * s)

            var veins = Path()
            let right: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(17, 11, 24.5, 7.6), (17, 17, 26, 14.4), (17, 23, 24.4, 21.6), (17, 28.5, 22, 27.9)]
            let left: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(17, 11, 9.5, 7.6), (17, 17, 8, 14.4), (17, 23, 9.6, 21.6), (17, 28.5, 12, 27.9)]
            for v in right + left { veins.move(to: p(v.0, v.1)); veins.addLine(to: p(v.2, v.3)) }
            ctx.stroke(veins, with: .color(tint), style: StrokeStyle(lineWidth: 1.25 * s, lineCap: .round))

            let nodes: [(CGFloat, CGFloat, CGFloat)] = [(24.5, 7.6, 1.9), (26, 14.4, 1.9), (24.4, 21.6, 1.9), (22, 27.9, 1.6),
                                                       (9.5, 7.6, 1.9), (8, 14.4, 1.9), (9.6, 21.6, 1.9), (12, 27.9, 1.6)]
            for n in nodes {
                let c = p(n.0, n.1); let r = n.2 * s
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(tint))
            }
            let t = p(17, 4); let tr = 2.6 * s
            ctx.fill(Path(ellipseIn: CGRect(x: t.x - tr, y: t.y - tr, width: 2 * tr, height: 2 * tr)), with: .color(tip))
        }
        .frame(width: size * 34 / 38, height: size)
        .accessibilityHidden(true)
    }
}

/// "natur" light, "Mesh" bold, as on the site.
struct Wordmark: View {
    var size: CGFloat = 21

    var body: some View {
        (Text("natur").font(Brand.text(size, weight: .regular)) + Text("Mesh").font(Brand.text(size, weight: .bold)))
            .foregroundStyle(Brand.birch)
            .kerning(-0.3)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) { LeafMark(size: 26); Wordmark(size: 19) }
    }
}

extension View {
    func card() -> some View {
        self.padding(14)
            .background(Brand.bark, in: RoundedRectangle(cornerRadius: Brand.corner, style: .continuous))
    }
}

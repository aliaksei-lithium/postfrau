import AppKit
import CoreGraphics
import Foundation

// The Postfrau mark: a postwoman in flight.
//
// Regenerate the icon glyph with:
//
//     xcrun swiftc -O Tools/make-icon-glyph.swift -o /tmp/make-icon-glyph
//     /tmp/make-icon-glyph Postfrau/Resources/Postfrau.icon/Assets/glyph.png
//
// It is a script rather than a checked-in drawing because the shape took many rounds of
// render-look-adjust; keeping the geometry in source makes the next round an edit, not a redraw.
//
// Drawn white on transparent so `icon.json`'s purple gradient shows through and macOS can derive
// the tinted and clear appearances from the same shape.
//
// Shaped after Postman's mark, which is close to abstract: a detached circle and one tapered
// wedge. So there are no separate arms here — the arm is a line cut *into* the body, which is
// what keeps the silhouette legible at 32 px. Three things were each got wrong first and are
// worth not re-discovering:
//
//   * The figure is built UPRIGHT — feet at y = 0, head at the top — and the whole frame is then
//     rotated into the climb. Drawing her already-diagonal turned every curve into guesswork and
//     produced shapes that read as animals.
//   * The hem bows *outward*. An inward-curving hem between two sharp corners is a fishtail.
//   * Framing is measured, not guessed: a probe pass renders small and centred, its alpha
//     bounding box is read back, and the scale and offset that centre her are computed from it.
//     The `precondition` matters — a clipped probe reports the canvas as the bounding box and
//     silently yields a cropped icon.
//
// In the local frame, +x is her front and +y is the direction she is heading.

let size = 1024
let safeInset = 40.0                       // macOS icon art keeps clear of the rounded corners
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

func newContext() -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func render(into ctx: CGContext, scale: Double, dx: Double, dy: Double) {
    ctx.setAllowsAntialiasing(true)

    func fill(_ path: CGMutablePath) { ctx.addPath(path); ctx.setFillColor(white); ctx.fillPath() }

    /// Strokes a jointed limb one segment at a time, so it can taper from thigh to ankle. Round
    /// caps do the work of joints — steadier than modelling each limb as an outline.
    func limb(_ joints: [CGPoint], _ widths: [Double]) {
        ctx.setStrokeColor(white)
        ctx.setLineCap(.round)
        for i in 0..<(joints.count - 1) {
            ctx.setLineWidth(widths[i])
            ctx.move(to: joints[i])
            ctx.addLine(to: joints[i + 1])
            ctx.strokePath()
        }
    }

    /// Cuts a hole in what is already drawn — the only way to get a line *inside* a solid mark.
    func carve(_ draw: () -> Void) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        draw()
        ctx.restoreGState()
    }

    ctx.translateBy(x: dx, y: dy)
    ctx.rotate(by: -44 * .pi / 180)
    ctx.scaleBy(x: scale, y: scale)

    // —— the dress: narrow shoulders, bust, waist, then a skirt ——
    let hemFront = p(140, 350), hemBack = p(-188, 300)
    let body = CGMutablePath()
    body.move(to: p(-60, 700))                                      // shoulder, back
    body.addCurve(to: p(70, 708), control1: p(-24, 742), control2: p(34, 746))
    body.addCurve(to: p(106, 612), control1: p(104, 690), control2: p(112, 650))  // the bust
    body.addCurve(to: p(52, 496), control1: p(100, 566), control2: p(66, 534))    // the waist
    body.addCurve(                                                  // skirt, front edge
        to: hemFront, control1: p(94, 440), control2: p(hemFront.x - 12, hemFront.y + 70))
    body.addCurve(                                                  // the hem, bowed outward
        to: hemBack,
        control1: p(70, hemFront.y - 76), control2: p(-96, hemBack.y - 74))
    body.addCurve(                                                  // skirt, back edge
        to: p(-54, 496),
        control1: p(hemBack.x + 30, hemBack.y + 74), control2: p(-88, 424))
    body.addCurve(to: p(-60, 700), control1: p(-58, 566), control2: p(-62, 636))
    body.closeSubpath()
    fill(body)

    // —— legs, trailing below the hem ————————————————————————————
    // What settles the shape as a person in a skirt rather than an abstract wedge.
    limb([p(26, 330), p(-16, 190), p(-58, 96)], [56, 34])
    limb([p(-78, 318), p(-124, 196), p(-166, 116)], [50, 30])

    // —— head, and the bun ————————————————————————————————————————
    // One small circle overlapping the skull. It survives 32 px, where anything shaped like
    // flowing hair turns into a smudge on the side of the head.
    let skull = p(16, 826), skullRadius = 74.0
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: -92, y: 818, width: 62, height: 62))
    ctx.fillEllipse(
        in: CGRect(x: skull.x - skullRadius, y: skull.y - skullRadius,
                   width: skullRadius * 2, height: skullRadius * 2))

    // —— the arm, cut rather than drawn ——————————————————————————
    // A thin line is all it needs to be: pressed along her side, in the line of the body.
    carve {
        ctx.setLineCap(.round)
        ctx.setLineWidth(20)
        ctx.setStrokeColor(white)
        ctx.move(to: p(48, 688))
        ctx.addCurve(to: p(72, 512), control1: p(78, 632), control2: p(80, 570))
        ctx.strokePath()
    }
}

/// The tight alpha bounding box of what was drawn, in canvas pixels (y measured from the top).
func bounds(of ctx: CGContext) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = size, minY = size, maxX = -1, maxY = -1
    for y in 0..<size {
        for x in 0..<size where bytes[(y * ctx.bytesPerRow) + x * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return (Double(minX), Double(minY), Double(maxX), Double(maxY))
}

// Pass one: draw small and centred, purely to measure. The probe has to fit inside the canvas or
// the bounding box it reports is the canvas, not the figure.
let probeScale = 0.5, probeX = 512.0, probeY = 512.0
let probe = newContext()
render(into: probe, scale: probeScale, dx: probeX, dy: probeY)
let b = bounds(of: probe)
precondition(
    b.minX > 0 && b.minY > 0 && b.maxX < Double(size) - 1 && b.maxY < Double(size) - 1,
    "the probe clipped: measure at a smaller scale")

let target = Double(size) - safeInset * 2
let k = target / max(b.maxX - b.minX, b.maxY - b.minY)
// The transform is translate → rotate → scale, so a local point lands at (dx, dy) + R·S·q.
// Scaling by `k` about the translation origin moves the measured centre by the same factor, which
// is what lets the offset be solved for directly.
let scale = probeScale * k
let dx = Double(size) / 2 - k * ((b.minX + b.maxX) / 2 - probeX)
let dy = Double(size) / 2 - k * ((Double(size) - (b.minY + b.maxY) / 2) - probeY)

let ctx = newContext()
render(into: ctx, scale: scale, dx: dx, dy: dy)
let final = bounds(of: ctx)
print(String(
    format: "scale %.3f  bbox x %.0f…%.0f  y %.0f…%.0f",
    scale, final.minX, final.maxX, final.minY, final.maxY))

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

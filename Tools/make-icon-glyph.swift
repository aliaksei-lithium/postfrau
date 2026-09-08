import AppKit
import CoreGraphics
import Foundation

// The Postfrau mark: a postwoman in flight, carrying a letter.
//
// Regenerate the icon glyph with:
//
//     xcrun swiftc -O Tools/make-icon-glyph.swift -o /tmp/make-icon-glyph
//     /tmp/make-icon-glyph Postfrau/Resources/Postfrau.icon/Assets/glyph.png
//
// It is a script rather than a checked-in drawing because the shape needed a dozen rounds of
// "render it, look at it, move a control point"; keeping the geometry in source makes the next
// round an edit instead of a redraw.
//
// Drawn white on transparent so `icon.json`'s purple gradient shows through and macOS can derive
// the tinted and clear appearances from the same shape.
//
// The figure is built UPRIGHT — feet at y = 0, head at the top — because anatomy is only easy to
// get right standing up. The frame is then rotated so her body axis points up and to the right:
// the classic flight pose, body along the direction of travel with the chest facing outward. In
// the local frame, +x is her front and +y is the direction she is heading.
//
// Framing is measured rather than guessed: the figure is drawn once, its alpha bounding box is
// read back, and the scale and offset that centre it in the icon's safe area are computed from
// that before the final pass.

let size = 1024
let safeInset = 34.0                        // macOS icon art keeps clear of the rounded corners
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let faint = CGColor(red: 1, green: 1, blue: 1, alpha: 0.34)

func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

func newContext() -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func render(into ctx: CGContext, scale: Double, dx: Double, dy: Double) {
    ctx.setAllowsAntialiasing(true)

    func fill(_ path: CGMutablePath, _ colour: CGColor = white) {
        ctx.addPath(path); ctx.setFillColor(colour); ctx.fillPath()
    }
    /// Strokes a jointed limb one segment at a time, so it can taper from thigh to ankle. Round
    /// caps do the work of joints — cheaper and steadier than modelling each limb as an outline.
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

    ctx.translateBy(x: dx, y: dy)
    ctx.rotate(by: -48 * .pi / 180)
    ctx.scaleBy(x: scale, y: scale)

    // —— speed lines, trailing below and behind ————————————————
    for (x, y, length, thickness) in [
        (-250.0, 300.0, 210.0, 34.0), (-140.0, 170.0, 280.0, 34.0), (-360.0, 470.0, 150.0, 30.0),
    ] {
        let t = CGMutablePath()
        t.addRoundedRect(
            in: CGRect(x: x, y: y - length, width: thickness, height: length),
            cornerWidth: thickness / 2, cornerHeight: thickness / 2)
        fill(t, faint)
    }

    // —— legs, trailing below with air between them ————————————
    limb([p(-46, 486), p(-92, 262), p(-142, 92), p(-208, 56)], [78, 56, 34])   // far leg
    limb([p(40, 488), p(10, 252), p(-28, 62), p(-96, 20)], [84, 60, 36])       // near leg

    // —— trailing arm, swept back along her side ————————————————
    limb([p(-96, 640), p(-166, 540), p(-198, 458)], [50, 40])

    // —— leading arm, reaching ahead ————————————————————————————
    //    Drawn before the torso so the bust keeps a clean outline; the arm is one continuous
    //    silhouette either way, and only the overlap order decides which contour survives.
    limb([p(78, 672), p(130, 830), p(170, 962)], [50, 40])

    // —— hair: a ponytail sweeping off the nape ————————————————
    //    Its inner edge is an arc of the skull itself, so however the tail is shaped the hair can
    //    never drift off the head — every freehand version either detached or read as a blade.
    //    Both outer edges bow: a straight run between the nape and the tip reads as a cone.
    let skull = p(10, 800), skullRadius = 70.0
    func onSkull(_ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return p(skull.x + skullRadius * cos(a), skull.y + skullRadius * sin(a))
    }
    let hair = CGMutablePath()
    // The arc runs a little inside the skull so the two fills overlap; sharing an edge exactly
    // leaves a hairline seam where the antialiasing of each meets.
    hair.move(to: onSkull(150))
    hair.addArc(
        center: skull, radius: skullRadius - 8,
        startAngle: 150 * .pi / 180, endAngle: 250 * .pi / 180, clockwise: false)
    hair.addCurve(to: p(-192, 700), control1: p(-80, 700), control2: p(-152, 684))
    hair.addCurve(to: p(-176, 758), control1: p(-210, 716), control2: p(-204, 746))
    hair.addCurve(to: onSkull(150), control1: p(-128, 784), control2: p(-92, 818))
    hair.closeSubpath()
    fill(hair)

    // —— skirt: an A-line reaching the knee ————————————————————
    let skirt = CGMutablePath()
    skirt.move(to: p(56, 496))                        // waist, front
    skirt.addLine(to: p(-58, 496))                    // waist, back
    skirt.addCurve(to: p(-218, 236), control1: p(-118, 408), control2: p(-176, 306))
    skirt.addCurve(to: p(126, 282), control1: p(-96, 194), control2: p(38, 218))
    skirt.addCurve(to: p(56, 496), control1: p(114, 376), control2: p(80, 436))
    skirt.closeSubpath()
    fill(skirt)

    // —— torso: shoulders, bust, waist ————————————————————————
    let torso = CGMutablePath()
    torso.move(to: p(-56, 486))                       // waist, back
    torso.addCurve(to: p(-112, 672), control1: p(-76, 560), control2: p(-104, 614))
    torso.addCurve(to: p(100, 682), control1: p(-62, 712), control2: p(48, 714))  // shoulders
    torso.addCurve(to: p(128, 608), control1: p(124, 668), control2: p(130, 642))
    torso.addCurve(to: p(64, 546), control1: p(126, 574), control2: p(96, 550))   // the bust
    torso.addCurve(to: p(58, 486), control1: p(60, 522), control2: p(58, 504))
    torso.closeSubpath()
    fill(torso)

    // —— neck and head ————————————————————————————————————————
    limb([p(-2, 656), p(8, 754)], [66])
    ctx.setFillColor(white)
    ctx.fillEllipse(
        in: CGRect(x: skull.x - skullRadius, y: skull.y - skullRadius,
                   width: skullRadius * 2, height: skullRadius * 2))

    // —— the letter ————————————————————————————————————————————
    ctx.saveGState()
    ctx.translateBy(x: 178, y: 974)
    ctx.rotate(by: -0.42)
    let letter = CGMutablePath()
    letter.addRoundedRect(
        in: CGRect(x: -100, y: -48, width: 200, height: 142), cornerWidth: 18, cornerHeight: 18)
    fill(letter)
    // The flap is cut out rather than drawn, so it stays crisp at every size.
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(17)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.move(to: p(-74, 72))
    ctx.addLine(to: p(0, 14))
    ctx.addLine(to: p(74, 72))
    ctx.strokePath()
    ctx.restoreGState()
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

// Pass one: draw small and centred, purely to measure. The probe has to fit inside the canvas
// or the bounding box it reports is the canvas, not the figure.
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
// Scaling by `k` about the translation origin therefore moves the measured centre by the same
// factor, which is what lets the offset be solved for directly.
let offsetX = (b.minX + b.maxX) / 2 - probeX
let offsetY = (Double(size) - (b.minY + b.maxY) / 2) - probeY
let scale = probeScale * k
let dx = Double(size) / 2 - k * offsetX
let dy = Double(size) / 2 - k * offsetY

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

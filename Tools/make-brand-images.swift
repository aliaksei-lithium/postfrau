import AppKit
import Foundation

// Builds the two images the repository shows the outside world:
//
//     docs/images/icon.png            — the app mark, for the README header
//     docs/images/social-preview.png  — 1280×640, GitHub's Open Graph card
//
// Regenerate both with:
//
//     xcrun swiftc -O Tools/make-brand-images.swift -o /tmp/make-brand-images
//     /tmp/make-brand-images
//
// These compose the icon from `Postfrau.icon`'s own gradient and glyph rather than reading the
// icon macOS renders for the built app. That keeps them reproducible from a clean checkout, and
// avoids baking macOS 26's glass-and-shadow treatment into a flat PNG, where it reads as grime.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let glyphURL = root.appending(path: "Postfrau/Resources/Postfrau.icon/Assets/glyph.png")
guard let glyph = NSImage(contentsOf: glyphURL) else {
    FileHandle.standardError.write(Data("no glyph at \(glyphURL.path)\n".utf8))
    exit(1)
}

// The same two stops as `icon.json`, so the brand images cannot drift from the app's own icon.
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
    ending: NSColor(srgbRed: 0.55, green: 0.28, blue: 0.86, alpha: 1))!

/// Draws the icon: the gradient inside macOS's rounded-square mask, with the glyph over it.
func drawIcon(in rect: NSRect) {
    let context = NSGraphicsContext.current!
    context.saveGraphicsState()
    // 22.37% of the side is the corner radius Apple's macOS icon grid uses.
    let radius = rect.width * 0.2237
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    gradient.draw(in: rect, angle: -90)
    glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    context.restoreGraphicsState()
}

func write(_ image: NSImage, to path: String) throws {
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
        .representation(using: .png, properties: [:])!
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    print(path)
}

// —— the README icon ————————————————————————————————————————————
let iconSide = 512.0
let icon = NSImage(size: NSSize(width: iconSide, height: iconSide))
icon.lockFocus()
drawIcon(in: NSRect(x: 0, y: 0, width: iconSide, height: iconSide))
icon.unlockFocus()
try write(icon, to: "docs/images/icon.png")

// —— the social preview ————————————————————————————————————————
// 1280×640 is GitHub's stated size for an Open Graph card. It is shown as small as a Slack
// unfurl, so everything here is deliberately oversized: a 320 pt icon and a 96 pt title.
let card = NSImage(size: NSSize(width: 1280, height: 640))
card.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: 1280, height: 640)
NSColor(srgbRed: 0.055, green: 0.055, blue: 0.075, alpha: 1).setFill()
bounds.fill()

// A wash of the brand purple behind the icon, so the card is not a black rectangle. It is drawn
// across the whole canvas with the centre pushed left, rather than into a rect around the icon:
// a radial gradient is clipped to its rect, and that rect's edge showed up as a seam down the
// middle of the card.
NSGraphicsContext.current!.saveGraphicsState()
NSGradient(
    starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 0.22),
    ending: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 0))!
    .draw(in: bounds, relativeCenterPosition: NSPoint(x: -0.6, y: 0))
NSGraphicsContext.current!.restoreGraphicsState()

let iconRect = NSRect(x: 96, y: 160, width: 320, height: 320)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
drawIcon(in: iconRect)
NSGraphicsContext.current!.restoreGraphicsState()

func draw(_ text: String, _ font: NSFont, _ colour: NSColor, at point: NSPoint) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    NSAttributedString(
        string: text,
        attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
    ).draw(at: point)
}

let textX = 500.0
draw(
    "Postfrau", NSFont.systemFont(ofSize: 96, weight: .bold), .white,
    at: NSPoint(x: textX, y: 356))
draw(
    "An HTTP client for macOS 26", NSFont.systemFont(ofSize: 40, weight: .medium),
    NSColor(white: 0.82, alpha: 1), at: NSPoint(x: textX, y: 286))
draw(
    "Collections are JSON files in a folder you choose.",
    NSFont.systemFont(ofSize: 28, weight: .regular), NSColor(white: 0.55, alpha: 1),
    at: NSPoint(x: textX, y: 232))
draw(
    "No account, no cloud, nothing uploaded.",
    NSFont.systemFont(ofSize: 28, weight: .regular), NSColor(white: 0.55, alpha: 1),
    at: NSPoint(x: textX, y: 194))

card.unlockFocus()
try write(card, to: "docs/images/social-preview.png")

#!/usr/bin/env swift
//
// Turn the master installer artwork into the background pair the DMG needs.
//
// Two separate things are wrong with handing Finder a single large PNG, and both produce a window
// that does not look like the artwork:
//
//   1. Finder does not scale a background to fit. It draws it at its own size, so an image twice the
//      size of the window shows only its top-left quarter. The background therefore has to be
//      supplied at exactly the window's size in points, with an @2x partner for Retina — which is
//      the same 1x/@2x pairing AppKit uses. dmgbuild picks the pair up automatically and combines
//      them with `tiffutil -cathidpicheck` into one multi-representation TIFF.
//
//   2. The painted icons have to end up at a size Finder will actually honour. The measured layout
//      says what `icon_size` the painted icons imply (see dmg-layout.swift: the painted tile divided
//      by the icon body ratio, because a drawn icon only fills ~80% of its box). If that is larger
//      than the largest icon size Finder is known to accept, the real icons would be clamped and the
//      painted ones would stick out from behind them, so the artwork is scaled down until the
//      implied size fits. Scaling the art rather than the icon keeps the two aligned.
//
// Usage:
//   swift scripts/make-dmg-background.swift --source Resources/dmg-background.png \
//       --layout build/dmg-layout.json --out build/dmg-background.png [--limit 256] [--json]
//
// Writes <out> (1x) and <out>@2x (2x), both exactly twice/half of each other, and prints the window
// size and icon size they imply. Exit status is non-zero if the result would not fit the limit.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Finder's icon view is documented as going up to 512, but only 256 has a concrete report of being
// honoured, and an over-large value is silently clamped — which reintroduces the doubled icon rather
// than failing loudly. 256 is comfortably inside every published range, so the artwork is scaled to
// fit it.
let defaultLimit = 256

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-dmg-background: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var source: String?
var layoutPath: String?
var output: String?
var limit = defaultLimit
var emitJSON = false

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
        guard index + 1 < arguments.count else { die("\(argument) needs a value") }
        index += 1
        return arguments[index]
    }
    switch argument {
    case "--source": source = value()
    case "--layout": layoutPath = value()
    case "--out": output = value()
    case "--limit":
        guard let parsed = Int(value()) else { die("--limit needs a number") }
        limit = parsed
    case "--json": emitJSON = true
    default: die("unknown option \(argument)")
    }
    index += 1
}

guard let sourcePath = source, let layoutFile = layoutPath, let outPath = output else {
    die("usage: make-dmg-background.swift --source <art.png> --layout <layout.json> --out <background.png>")
}

guard let sourceData = FileManager.default.contents(atPath: layoutFile),
      let layout = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
      let iconSize = layout["iconSize"] as? Int else {
    die("could not read the layout's iconSize from \(layoutFile)")
}

let layoutArtwork = layout["artwork"] as? [String: Any]
let layoutWidth = layoutArtwork?["width"] as? Int
let layoutHeight = layoutArtwork?["height"] as? Int

guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    die("could not read \(sourcePath)")
}

// Scale from the image that was actually read, never from the size the layout happens to record. The
// layout's icon size was measured from whatever artwork produced it, so if the two disagree the
// arithmetic below would silently size a window around icons that are not in this image.
let artWidth = image.width
let artHeight = image.height
if let recordedWidth = layoutWidth, let recordedHeight = layoutHeight,
   recordedWidth != artWidth || recordedHeight != artHeight {
    die("""
    the layout describes a \(recordedWidth)x\(recordedHeight) artwork, but \(sourcePath) is \
    \(artWidth)x\(artHeight). Its icon size was measured from the other image, so scaling this one \
    by it would produce a window whose icons do not line up. Re-measure the artwork you are scaling.
    """)
}

// How much the art has to shrink for the implied icon size to sit inside the limit. The implied size
// is proportional to the painted tile, so scaling by the ratio of the two nominal sizes is the whole
// calculation — but the measured layout rounds its sizes to whole points, and that rounding is
// recomputed (not scaled) when the art is measured again, so a few points of headroom are kept.
let headroom = 3
let targetNominal = limit - headroom
let reduction = iconSize > targetNominal ? Double(targetNominal) / Double(iconSize) : 1.0

// Even dimensions so the 1x is exactly half the 2x and tiffutil's `-cathidpicheck` holds.
func even(_ value: Double) -> Int {
    let rounded = Int(value.rounded())
    return rounded % 2 == 0 ? rounded : rounded + 1
}

let twoXWidth = even(Double(artWidth) * reduction)
let twoXHeight = even(Double(artHeight) * reduction)
let oneXWidth = twoXWidth / 2
let oneXHeight = twoXHeight / 2

func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // Lanczos-quality resampling, then the banding-free path for the gradients in this art.
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

func write(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

guard let twoX = resized(image, width: twoXWidth, height: twoXHeight) else {
    die("could not resample the artwork")
}
guard let oneX = resized(twoX, width: oneXWidth, height: oneXHeight) else {
    die("could not resample the 1x background")
}

// The @2x is written from the master and the 1x from the @2x, so the two are a true pair rather than
// two independent resamplings of the master that could disagree by a pixel on an odd edge.
let twoXPath = (outPath as NSString).deletingPathExtension + "@2x." + (outPath as NSString).pathExtension
guard write(twoX, to: twoXPath) else { die("could not write \(twoXPath)") }
guard write(oneX, to: outPath) else { die("could not write \(outPath)") }

// Verify what was actually written rather than what was intended.
func dimensions(_ path: String) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

guard let written1x = dimensions(outPath), written1x == (oneXWidth, oneXHeight) else {
    die("the 1x background is not \(oneXWidth)x\(oneXHeight) on disk")
}
guard let written2x = dimensions(twoXPath), written2x == (twoXWidth, twoXHeight) else {
    die("the @2x background is not \(twoXWidth)x\(twoXHeight) on disk")
}
guard written2x.0 == written1x.0 * 2, written2x.1 == written1x.1 * 2 else {
    die("the two backgrounds are not a 1x/@2x pair: \(written1x) vs \(written2x)")
}

// What the artwork will imply once it is measured again, estimated from the painted tile rather than
// from the nominal size, so the icon body ratio is not applied twice.
let bodyRatio = (layout["iconBodyRatio"] as? Double) ?? (824.0 / 1024.0)
let paintedIconSize = (layout["paintedIconSize"] as? Int) ?? Int((Double(iconSize) * bodyRatio))
let scaledPaintedTile = Double(paintedIconSize) * reduction
let impliedIconSize = Int((scaledPaintedTile / bodyRatio).rounded(.up)) + (iconSize - Int((Double(paintedIconSize) / bodyRatio).rounded(.up)))

let summary: [String: Any] = [
    "source": sourcePath,
    "oneX": ["path": outPath, "width": written1x.0, "height": written1x.1],
    "twoX": ["path": twoXPath, "width": written2x.0, "height": written2x.1],
    "window": ["width": written1x.0, "height": written1x.1],
    "reduction": reduction,
    "impliedIconSize": impliedIconSize,
    "limit": limit,
]

if emitJSON {
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    print()
} else {
    let percent = String(format: "%.1f", reduction * 100)
    print("artwork:      \(artWidth)x\(artHeight) px")
    print("background:   \(written1x.0)x\(written1x.1) points  (\(twoXWidth)x\(twoXHeight) at 2x)")
    print("scale:        \(percent)% of the master")
    print("icon size:    \(impliedIconSize) points implied by the painted icons (limit \(limit))")
}

guard impliedIconSize <= limit else {
    die("the painted icons still imply an icon size of \(impliedIconSize) > \(limit)")
}

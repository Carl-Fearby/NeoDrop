#!/usr/bin/env swift
//
// Compose the installer background from the artwork it is given.
//
// It is cropped to the window's shape and nothing is drawn on it. Earlier versions tried to line the
// real icons up over copies of themselves that the artwork painted, and then to reuse that artwork's
// light and its arrow; every element the background draws is something the icons have to line up with,
// and something that can be wrong. This one draws nothing, so the only thing that can disagree with
// the window is the crop, which is the same maths every time.
//
// It also writes the layout that places the icons and that scripts/make-dmg.py checks them against.
//
// Usage:
//   swift scripts/make-dmg-artwork.swift --source Resources/dmg-background.png \
//       --out build/dmg-background.png --layout-out build/dmg-layout.json [--json]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The design, in view points: one row, evenly spaced across the window. Wider than the icon row needs,
// so the cells are not crowding each other and Finder has room to lay them out where it is asked to.
let window = (width: 960, height: 458)
let slotCentres: [(x: Double, y: Double)] = [(160, 200), (480, 200), (800, 200)]
/// How much of the artwork's brightness to keep.
///
/// Finder decides the label colour from the background: dark text on a bright picture, white with a
/// shadow on a dark one. This wallpaper is bright, so the labels came out black on mid-blue wave —
/// hard to read and not what the window should look like. Multiplying it down keeps the waves and the
/// hue, and puts Finder back on white text.
///
/// The threshold is Finder's, not ours, and it is picked from the whole background: 0.55 was not dark
/// enough (measured — black ink over the whole label row) and the near-black artwork of the first
/// version was. 0.28 is measured white; `--brightness` exists so the flip can be re-measured rather
/// than believed.
var brightness = 0.28
/// The icon size Finder is asked for, and the fraction of that box an icon's body fills.
let iconSize = 254.0
let iconBodyRatio = 824.0 / 1024.0
/// The box each icon is expected to cover: the drop target, as a design number, not a painting.
let slotSize = 190.0
let labelGap = 6.0
let labelHeight = 22.0
let labelWidth = 150.0

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-dmg-artwork: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var source: String?
var output: String?
var layoutOutput: String?
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
    case "--out": output = value()
    case "--layout-out": layoutOutput = value()
    case "--brightness":
        guard let parsed = Double(value()), parsed > 0, parsed <= 1 else { die("--brightness needs a value in (0, 1]") }
        brightness = parsed
    case "--json": emitJSON = true
    default: die("unknown option \(argument)")
    }
    index += 1
}

guard let sourcePath = source, let outPath = output, let layoutPath = layoutOutput else {
    die("usage: make-dmg-artwork.swift --source <artwork.png> --out <background.png> --layout-out <layout.json>")
}

guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    die("could not read \(sourcePath)")
}

let scale = 2
let canvasWidth = window.width * scale, canvasHeight = window.height * scale

// Crop rather than stretch: scale the artwork until it covers the window, then centre it. A stretched
// gradient reads as a mistake and the wallpaper's waves are its whole point.
let fill = max(Double(canvasWidth) / Double(artwork.width), Double(canvasHeight) / Double(artwork.height))
let drawnWidth = Double(artwork.width) * fill, drawnHeight = Double(artwork.height) * fill

/// The one and only thing drawn, at both screen densities, from the same numbers.
func compose(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("could not create a \(width)x\(height) context")
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.draw(artwork, in: CGRect(x: (Double(width) - drawnWidth) / 2,
                                     y: (Double(height) - drawnHeight) / 2,
                                     width: drawnWidth, height: drawnHeight))
    context.setBlendMode(.multiply)
    context.setFillColor(CGColor(red: brightness, green: brightness, blue: brightness, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setBlendMode(.normal)
    return context
}

func writePNG(_ context: CGContext, to path: String) -> Bool {
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

let twoX = compose(width: canvasWidth, height: canvasHeight)
let oneX = compose(width: window.width, height: window.height)
let twoXPath = (outPath as NSString).deletingPathExtension + "@2x." + (outPath as NSString).pathExtension
guard writePNG(twoX, to: twoXPath) else { die("could not write \(twoXPath)") }
guard writePNG(oneX, to: outPath) else { die("could not write \(outPath)") }

func dimensions(_ path: String) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}
guard let written1x = dimensions(outPath), written1x == (window.width, window.height) else {
    die("the 1x background is not \(window.width)x\(window.height) on disk")
}
guard let written2x = dimensions(twoXPath), written2x == (canvasWidth, canvasHeight) else {
    die("the @2x background is not \(canvasWidth)x\(canvasHeight) on disk")
}

/// A slot as the rest of the build reads it: the box an icon is expected to cover, its centre, and
/// the label Finder draws under it.
func slot(_ centre: (x: Double, y: Double)) -> [String: Any] {
    let labelTop = centre.y + iconSize / 2 + labelGap
    return [
        "box": [Int((centre.x - slotSize / 2).rounded()), Int((centre.y - slotSize / 2).rounded()),
                Int(slotSize), Int(slotSize)],
        "centre": [Int(centre.x.rounded()), Int(centre.y.rounded())],
        "label": [Int((centre.x - labelWidth / 2).rounded()), Int(labelTop.rounded()),
                  Int(labelWidth), Int(labelHeight)],
        "size": Int(iconSize),
    ]
}

// Nothing is drawn under the labels, so there is no caption to clear: the checks in make-dmg.py skip
// it when these are empty.
let layout: [String: Any] = [
    "window": ["width": window.width, "height": window.height],
    "artwork": ["scale": scale, "width": written2x.0, "height": written2x.1],
    "iconSize": Int(iconSize),
    "iconBodyRatio": iconBodyRatio,
    "paintedIconSize": Int(slotSize),
    "labelGap": Int(labelGap),
    "labelHeight": Int(labelHeight),
    "rowCentre": Int(slotCentres[1].y),
    "band": 0,
    "captionTop": window.height,
    "captionBox": [0, window.height, 0, 0],
    "appIcon": slot(slotCentres[1]),
    "applicationsIcon": slot(slotCentres[2]),
    "noticeIcon": slot(slotCentres[0]),
]

guard let layoutData = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]),
      (try? layoutData.write(to: URL(fileURLWithPath: layoutPath))) != nil else {
    die("could not write \(layoutPath)")
}

if emitJSON {
    let summary: [String: Any] = [
        "source": sourcePath,
        "oneX": ["path": outPath, "width": written1x.0, "height": written1x.1],
        "twoX": ["path": twoXPath, "width": written2x.0, "height": written2x.1],
        "window": ["width": window.width, "height": window.height],
        "noticeBand": 0,
        "brightness": brightness,
        "layout": layoutPath,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        print()
    }
} else {
    print("background:   \(written1x.0)x\(written1x.1) points (\(written2x.0)x\(written2x.1) at 2x)")
    print("artwork:      \(artwork.width)x\(artwork.height) cropped to cover, scale \(String(format: "%.2f", fill))")
    print("icons:        " + slotCentres.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ")
          + " at \(Int(iconSize))pt")
    print("drawn in it:  nothing — the artwork itself, cropped and multiplied to \(String(format: "%.0f", brightness * 100))% brightness")
}

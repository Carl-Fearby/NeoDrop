#!/usr/bin/env swift
//
// Check the menu bar icon before it goes into the bundle.
//
// A status item image fails in ways that a file listing cannot show, and every one of them is silent:
//
//   * an opaque background renders as a solid tinted block in the menu bar, because AppKit draws a
//     template image from its alpha channel and ignores the colour underneath entirely;
//   * a wrong pixel size (a 512 master dropped in as the 1x, say) gets scaled by AppKit and looks
//     soft, which is easy to mistake for a bad design;
//   * the wrong file among a set of near-identical ones — the white variant instead of the black
//     one — looks correct in isolation, and silhouette comparison cannot see the difference at all,
//     because the variants are identical in shape. Only the ink colour separates them;
//   * a 512 master dropped in as the 1x would pass a size check performed on the file rather than
//     on the artwork, so the glyph is also measured against its own canvas.
//
// Usage: swift scripts/verify-menubar-icon.swift [<1x> <2x> <3x>]
//        (defaults: Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png, Resources/MenuBarIcon@3x.png)
//
// Exit status: 0 when every check passes, 1 otherwise.

import Foundation
import CoreGraphics
import ImageIO

let expectedScales = [1, 2, 3]
let expectedBaseSize = 18          // the standard menu bar height at 1x
let minimumMargin = 1              // px of transparent breathing room on every side, at 1x
let minimumInkFraction = 0.25      // of the canvas; below this the glyph is a speck
let maximumInkFraction = 0.90      // above this there is no background left
let centringTolerance = 1          // px of asymmetry between opposite margins
let minimumGlyphHeight = 0.45      // of the canvas height; a status item icon shorter than this reads as tiny

var failures = 0
func pass(_ message: String) { print("  ok   \(message)") }
func fail(_ message: String) { print("  FAIL \(message)"); failures += 1 }
func note(_ message: String) { print("  --   \(message)") }

var paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    paths = ["Resources/MenuBarIcon.png", "Resources/MenuBarIcon@2x.png", "Resources/MenuBarIcon@3x.png"]
}
guard paths.count == 3 else {
    FileHandle.standardError.write(Data("usage: verify-menubar-icon.swift [<1x> <2x> <3x>]\n".utf8))
    exit(2)
}

/// One rasterised representation: its alpha channel at full resolution, plus the facts derived from it.
struct Representation {
    let path: String
    let scale: Int
    let width: Int
    let height: Int
    let alpha: [UInt8]
    let red: [UInt8]
    let green: [UInt8]
    let blue: [UInt8]

    func alpha(x: Int, y: Int) -> UInt8 { alpha[y * width + x] }

    /// Bounding box of pixels with meaningful alpha, as (minX, minY, maxX, maxY).
    var glyphBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x: x, y: y) > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX, maxY)
    }

}

func load(_ path: String, scale: Int) -> Representation? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drew else { return nil }

    var alpha = [UInt8](repeating: 0, count: width * height)
    var red = [UInt8](repeating: 0, count: width * height)
    var green = red, blue = red
    for index in 0..<(width * height) {
        alpha[index] = pixels[index * 4 + 3]
        red[index] = pixels[index * 4]
        green[index] = pixels[index * 4 + 1]
        blue[index] = pixels[index * 4 + 2]
    }
    return Representation(path: path, scale: scale, width: width, height: height,
                          alpha: alpha, red: red, green: green, blue: blue)
}

var representations: [Representation] = []

for (index, scale) in expectedScales.enumerated() {
    let path = paths[index]
    guard let representation = load(path, scale: scale) else {
        fail("\(path) is missing or unreadable")
        continue
    }
    note("\((path as NSString).lastPathComponent): \(representation.width)x\(representation.height) px at \(scale)x")
    representations.append(representation)
}

guard representations.count == 3 else {
    print("\n\(failures) check(s) failed.")
    exit(1)
}

// 1. Pixel sizes. A status item asks for 18 points; each representation has to be that times its
//    scale, or AppKit resamples one of them and that representation looks soft.
for representation in representations {
    let expectedWidth = expectedBaseSize * representation.scale
    let expectedHeight = expectedBaseSize * representation.scale
    if representation.width == expectedWidth && representation.height == expectedHeight {
        pass("the \(representation.scale)x is \(expectedWidth)x\(expectedHeight) px")
    } else {
        fail("the \(representation.scale)x is \(representation.width)x\(representation.height) px, expected \(expectedWidth)x\(expectedHeight)")
    }
}

// 2. Transparent background. This is the failure that makes the asset useless rather than merely
//    off: a template image is drawn from alpha alone, so an opaque background is a solid block.
for representation in representations {
    let corners = [
        representation.alpha(x: 0, y: 0),
        representation.alpha(x: representation.width - 1, y: 0),
        representation.alpha(x: 0, y: representation.height - 1),
        representation.alpha(x: representation.width - 1, y: representation.height - 1),
    ]
    if corners.allSatisfy({ $0 == 0 }) {
        pass("the \(representation.scale)x has a transparent background")
    } else {
        fail("the \(representation.scale)x has opaque corners \(corners); a template image would render as a solid block")
    }
}

// 3. A single ink colour. The app tints the template, so the colour itself is irrelevant — but a
//    multi-coloured or anti-aliased-to-grey glyph would mean the wrong kind of asset (a photograph
//    of an icon, a rendered preview) rather than a mask.
for representation in representations {
    var inkRed = 0, inkGreen = 0, inkBlue = 0, inkPixels = 0
    for index in representation.alpha.indices where representation.alpha[index] > 250 {
        inkRed += Int(representation.red[index])
        inkGreen += Int(representation.green[index])
        inkBlue += Int(representation.blue[index])
        inkPixels += 1
    }
    guard inkPixels > 0 else { fail("the \(representation.scale)x has no opaque pixels"); continue }
    let meanRed = inkRed / inkPixels, meanGreen = inkGreen / inkPixels, meanBlue = inkBlue / inkPixels
    let spread = max(meanRed, meanGreen, meanBlue) - min(meanRed, meanGreen, meanBlue)
    let luminance = (meanRed + meanGreen + meanBlue) / 3
    if spread <= 8 && (luminance <= 24 || luminance >= 231) {
        pass("the \(representation.scale)x is single-colour \(luminance <= 24 ? "black" : "white")")
    } else {
        fail("the \(representation.scale)x ink averages rgb(\(meanRed),\(meanGreen),\(meanBlue)); a template mask should be one flat colour")
    }
}

// 4. Breathing room. A glyph flush with the canvas edge crowds the neighbouring menu bar items, and
//    it also means the asset was cropped rather than exported at the right size.
for representation in representations {
    guard let box = representation.glyphBox else {
        fail("the \(representation.scale)x is entirely transparent")
        continue
    }
    let margins = [
        box.minX, box.minY,
        representation.width - 1 - box.maxX,
        representation.height - 1 - box.maxY,
    ]
    let glyphWidth = box.maxX - box.minX + 1
    let glyphHeight = box.maxY - box.minY + 1
    if margins.min()! >= minimumMargin {
        pass("the \(representation.scale)x glyph is \(glyphWidth)x\(glyphHeight) px with \(margins.min()!)-\(margins.max()!) px of padding")
    } else {
        fail("the \(representation.scale)x glyph touches the canvas edge (margins \(margins))")
    }
}

// 5. One colour polarity across the set. The plausible mistake with a delivered set of near-identical
//    files is shipping the wrong one, and the black and white variants are *identical in shape* — so
//    comparing silhouettes, which is the obvious check, cannot see that difference at all. Polarity
//    can. (The app tints the template, so either polarity renders correctly; a set that disagrees
//    means two different deliverables were mixed, which is the thing worth catching.)
var polarities: [Int] = []
for representation in representations {
    var inkRed = 0, inkGreen = 0, inkBlue = 0, inkPixels = 0
    for index in representation.alpha.indices where representation.alpha[index] > 250 {
        inkRed += Int(representation.red[index])
        inkGreen += Int(representation.green[index])
        inkBlue += Int(representation.blue[index])
        inkPixels += 1
    }
    guard inkPixels > 0 else { fail("the \(representation.scale)x has no ink to judge"); continue }
    let luminance = (inkRed + inkGreen + inkBlue) / (3 * inkPixels)
    polarities.append(luminance <= 24 ? 0 : (luminance >= 231 ? 1 : -1))
}
if polarities.count == 3, polarities.allSatisfy({ $0 == polarities[0] }), polarities[0] >= 0 {
    pass("all three representations are the same colour (\(polarities[0] == 0 ? "black" : "white"))")
} else {
    fail("the three representations disagree in colour (\(polarities)); the set is mixed up")
}

// 6. Centred on its canvas. An off-centre glyph shiftiness inside the status item, and it is what a
//    hand-trimmed export produces.
for representation in representations {
    guard let box = representation.glyphBox else { continue }
    let left = box.minX, right = representation.width - 1 - box.maxX
    let top = box.minY, bottom = representation.height - 1 - box.maxY
    if abs(left - right) <= centringTolerance && abs(top - bottom) <= centringTolerance {
        pass("the \(representation.scale)x glyph is centred (margins l\(left) r\(right) t\(top) b\(bottom))")
    } else {
        fail("the \(representation.scale)x glyph is off-centre (margins l\(left) r\(right) t\(top) b\(bottom))")
    }
}

// 7. A plausible amount of ink. A near-empty or near-solid asset means the alpha channel is not the
//    glyph: an all-opaque file would pass the corner test only by accident, and an all-transparent
//    one would render as nothing at all.
for representation in representations {
    var ink = 0
    for index in representation.alpha.indices where representation.alpha[index] > 128 { ink += 1 }
    let fraction = Double(ink) / Double(representation.width * representation.height)
    if fraction >= minimumInkFraction && fraction <= maximumInkFraction {
        pass("the \(representation.scale)x ink covers \(String(format: "%.0f", fraction * 100))% of the canvas")
    } else {
        fail("the \(representation.scale)x ink covers \(String(format: "%.0f", fraction * 100))% of the canvas, which is not a glyph mask")
    }
}

// 8. Tall enough to read. The point of checking the glyph against the canvas rather than the file's
//    own bounds is that a correct file size says nothing about how large the artwork inside it is.
for representation in representations {
    guard let box = representation.glyphBox else { continue }
    let glyphHeight = Double(box.maxY - box.minY + 1) / Double(representation.height)
    if glyphHeight >= minimumGlyphHeight {
        pass("the \(representation.scale)x glyph fills \(String(format: "%.0f", glyphHeight * 100))% of the menu bar height")
    } else {
        fail("the \(representation.scale)x glyph fills only \(String(format: "%.0f", glyphHeight * 100))% of the menu bar height")
    }
}

print()
if failures == 0 {
    print("Menu bar icon verified.")
    exit(0)
}
print("\(failures) check(s) failed.")
exit(1)

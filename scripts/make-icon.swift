#!/usr/bin/env swift
//
// Build NeoDrop.icns for the app bundle, Finder and the DMG.
//
// Two modes:
//   --source <png>   use the supplied artwork (the NAS render), masked into the macOS rounded
//                    square at the size Apple expects, with transparency outside it
//   (no --source)    fall back to artwork drawn procedurally with CoreGraphics, so the icon can
//                    always be regenerated even if the source image is not to hand
//
// Usage:
//   swift scripts/make-icon.swift build/NeoDrop.icns --source Resources/AppIcon.png
//   swift scripts/make-icon.swift build/NeoDrop.icns --verify
//   swift scripts/make-icon.swift build/NeoDrop.icns            # procedural fallback
//
// --verify re-checks the written files: that the mask really left the corners transparent, and
// that the artwork was not silently flipped. Both matter because nobody looks at a 1024px icon
// during a build, and an upside-down or square-cornered app icon is easy to ship by accident.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

var outputArgument: String?
var sourceArgument: String?
var verify = false

var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--source":
        index += 1
        sourceArgument = index < arguments.count ? arguments[index] : nil
    case "--verify":
        verify = true
    default:
        if outputArgument == nil { outputArgument = argument }
    }
    index += 1
}

let outputURL = URL(fileURLWithPath: outputArgument ?? (FileManager.default.currentDirectoryPath + "/build/NeoDrop.icns"))
let buildDirectory = outputURL.deletingLastPathComponent()
let iconsetURL = buildDirectory.appendingPathComponent("NeoDrop.iconset")
let masterPNG = buildDirectory.appendingPathComponent("NeoDrop-1024.png")

// macOS icon geometry: on a 1024x1024 canvas the artwork occupies an 824x824 rounded square,
// i.e. the canvas is inset by about 9.77% on every side, with a corner radius of ~22.4% of the
// body. Getting these two numbers right is what makes an icon look native next to Apple's.
let canvasInset: CGFloat = 0.0977
let cornerRadiusRatio: CGFloat = 0.2237
let masterPixels = 1024

// MARK: - Contexts and buffers

func makeContext(pixels: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

/// Rasterise an image into an RGBA buffer so pixels can be inspected.
///
/// The drawing happens inside `withUnsafeMutableBytes`; the buffer must not escape the closure
/// while the pointer is live.
func rgbaBuffer(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drew ? buffer : nil
}

// MARK: - Ground-truth band sampling

/// Mean brightness of horizontal bands, read straight from the file's own pixel data
/// (`CGDataProviderCopyData`), top band first.
///
/// Deliberately not drawn through a CGContext: re-rendering would apply the same transform to
/// both images and hide exactly the mistake this is here to catch.
func rawBands(of image: CGImage, bandCount: Int) -> [Double]? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = max(1, image.bitsPerPixel / 8)
    guard bytesPerRow > 0, image.height >= bandCount else { return nil }

    let bandHeight = image.height / bandCount
    var bands: [Double] = []
    bands.reserveCapacity(bandCount)

    for band in 0..<bandCount {
        // Raw image data is top-down, so band 0 is the top of the image.
        let startRow = band * bandHeight
        let endRow = band == bandCount - 1 ? image.height : startRow + bandHeight
        var total = 0.0
        var samples = 0
        for row in startRow..<endRow {
            let rowStart = row * bytesPerRow
            var column = 0
            while column < image.width {
                let offset = rowStart + column * bytesPerPixel
                if offset + 2 < data.count {
                    total += Double(data[offset]) + Double(data[offset + 1]) + Double(data[offset + 2])
                    samples += 3
                }
                column += 1
            }
        }
        bands.append(samples > 0 ? total / Double(samples) : 0)
    }
    return bands
}

/// Pearson correlation, used to compare a band sequence against another (or its reverse).
func correlation(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, a.count > 1 else { return 0 }
    let meanA = a.reduce(0, +) / Double(a.count)
    let meanB = b.reduce(0, +) / Double(b.count)
    var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
    for index in a.indices {
        let da = a[index] - meanA
        let db = b[index] - meanB
        covariance += da * db
        varianceA += da * da
        varianceB += db * db
    }
    guard varianceA > 0, varianceB > 0 else { return 0 }
    return covariance / (varianceA.squareRoot() * varianceB.squareRoot())
}

// MARK: - Renderers

/// The supplied artwork, masked into the macOS rounded square.
func drawArtworkIcon(source: CGImage, pixels: Int) -> CGImage? {
    guard let context = makeContext(pixels: pixels) else { return nil }
    let size = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.scaleBy(x: size, y: size)

    let body = CGRect(
        x: canvasInset,
        y: canvasInset,
        width: 1 - canvasInset * 2,
        height: 1 - canvasInset * 2
    )
    let corner = body.width * cornerRadiusRatio
    context.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.clip()
    context.draw(source, in: body)
    return context.makeImage()
}

/// Procedural fallback: the same drive-stack idea, drawn from scratch.
func drawFallbackIcon(pixels: Int) -> CGImage? {
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    let gradientStart = rgb(0.16, 0.42, 0.94)
    let gradientEnd = rgb(0.05, 0.72, 0.68)
    let driveColour = rgb(1, 1, 1, 0.96)
    let driveDim = rgb(1, 1, 1, 0.72)
    let badgeColour = rgb(1, 1, 1)
    let tickColour = rgb(0.03, 0.47, 0.42)

    guard let context = makeContext(pixels: pixels) else { return nil }
    let size = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.scaleBy(x: size, y: size)

    let body = CGRect(
        x: canvasInset,
        y: canvasInset,
        width: 1 - canvasInset * 2,
        height: 1 - canvasInset * 2
    )
    let corner = body.width * cornerRadiusRatio
    let background = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.saveGState()
    context.addPath(background)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [gradientStart, gradientEnd] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY),
            options: []
        )
    }
    context.restoreGState()

    let barWidth: CGFloat = 0.50
    let barHeight: CGFloat = 0.098
    let barX: CGFloat = 0.17
    for (index, y) in [CGFloat(0.635), 0.475, 0.315].enumerated() {
        let rect = CGRect(x: barX, y: y, width: barWidth, height: barHeight)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.setFillColor(index == 0 ? driveColour : (driveDim.copy(alpha: [1.0, 0.88, 0.76][index]) ?? driveColour))
        context.fillPath()

        let notch = CGPath(
            roundedRect: CGRect(x: rect.minX + 0.030, y: rect.minY + barHeight * 0.32,
                                width: 0.030, height: barHeight * 0.36),
            cornerWidth: 0.015, cornerHeight: 0.015, transform: nil
        )
        context.addPath(notch)
        context.setFillColor(gradientEnd.copy(alpha: 0.85) ?? gradientEnd)
        context.fillPath()
    }

    let badgeCentre = CGPoint(x: 0.735, y: 0.255)
    let badgeRadius: CGFloat = 0.155
    context.setFillColor(badgeColour)
    context.fillEllipse(in: CGRect(x: badgeCentre.x - badgeRadius, y: badgeCentre.y - badgeRadius,
                                   width: badgeRadius * 2, height: badgeRadius * 2))
    context.setStrokeColor(tickColour)
    context.setLineWidth(0.052)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: badgeCentre.x - 0.072, y: badgeCentre.y + 0.008))
    context.addLine(to: CGPoint(x: badgeCentre.x - 0.020, y: badgeCentre.y - 0.050))
    context.addLine(to: CGPoint(x: badgeCentre.x + 0.078, y: badgeCentre.y + 0.062))
    context.strokePath()

    return context.makeImage()
}

// MARK: - Plumbing

enum IconError: Error, CustomStringConvertible {
    case cannotReadSource(String)
    case cannotRender(Int)
    case cannotWrite(String)
    case iconutilFailed(Int32)
    case verificationFailed([String])

    var description: String {
        switch self {
        case .cannotReadSource(let path): return "Could not read the icon source image at \(path)"
        case .cannotRender(let pixels): return "Could not render the icon at \(pixels)px"
        case .cannotWrite(let name): return "Could not write \(name)"
        case .iconutilFailed(let status): return "iconutil exited with status \(status)"
        case .verificationFailed(let failures): return "Icon verification failed:\n  - " + failures.joined(separator: "\n  - ")
        }
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw IconError.cannotWrite(url.lastPathComponent)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.cannotWrite(url.lastPathComponent)
    }
}

func loadImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// The sizes macOS looks for inside an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Run

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)

/// The supplied artwork, if there is any. Resolved once so the renderers stay simple.
var resolvedArtwork: CGImage?
var artworkDescription: String?

if let sourceArgument {
    guard let loaded = loadImage(sourceArgument) else { throw IconError.cannotReadSource(sourceArgument) }
    resolvedArtwork = loaded
    artworkDescription = "\(sourceArgument) (\(loaded.width)x\(loaded.height), masked to the macOS squircle)"
} else {
    let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/AppIcon.png")
    if FileManager.default.fileExists(atPath: fallback.path), let loaded = loadImage(fallback.path) {
        resolvedArtwork = loaded
        artworkDescription = "Resources/AppIcon.png"
    }
}

let artwork = resolvedArtwork
if let artworkDescription {
    print("using artwork: \(artworkDescription)")
} else {
    print("no source artwork found; drawing the procedural fallback")
}

func render(pixels: Int) -> CGImage? {
    if let artwork { return drawArtworkIcon(source: artwork, pixels: pixels) }
    return drawFallbackIcon(pixels: pixels)
}

for variant in variants {
    guard let image = render(pixels: variant.pixels) else { throw IconError.cannotRender(variant.pixels) }
    try writePNG(image, to: iconsetURL.appendingPathComponent(variant.name))
}

// Keep the master render: it is what the checks below read back from disk.
guard let master = render(pixels: masterPixels) else { throw IconError.cannotRender(masterPixels) }
try writePNG(master, to: masterPNG)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw IconError.iconutilFailed(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: iconsetURL)
print("wrote \(outputURL.path)")

// MARK: - Verification

if verify {
    var failures: [String] = []

    // 1. The mask geometry. Sampled against the real macOS layout: an ~9.77% transparent margin
    //    around an 824px body with ~184px corner arcs. `alpha` is indexed top-down, matching the
    //    bitmap context's row order, and the mask is symmetric so that is unambiguous.
    if let buffer = rgbaBuffer(master, width: masterPixels, height: masterPixels) {
        func alpha(x: Int, y: Int) -> UInt8 {
            buffer[(y * masterPixels + x) * 4 + 3]
        }
        let margin = Int((Double(masterPixels) * canvasInset).rounded())
        let bodyMax = masterPixels - margin
        let centre = masterPixels / 2

        // Outside the body: the transparent margin macOS expects.
        let outside = [alpha(x: 2, y: 2), alpha(x: masterPixels - 3, y: 2),
                       alpha(x: 2, y: masterPixels - 3), alpha(x: masterPixels - 3, y: masterPixels - 3)]
        if outside.contains(where: { $0 != 0 }) {
            failures.append("the corners are opaque (alpha \(outside)) — the transparent margin is missing")
        } else {
            print("  ok   transparent margin present (icon body inset by \(margin)px)")
        }

        // Inside the body's bounding box but within a corner arc: this is what proves the icon is
        // a squircle rather than a hard square.
        let arcAlpha = alpha(x: margin + 6, y: bodyMax - 6)
        if arcAlpha != 0 {
            failures.append("the corner arc is filled (alpha \(arcAlpha)) — the rounded radius was not applied")
        } else {
            print("  ok   corners are rounded, not square")
        }

        // Edge midpoints just inside the body must carry artwork.
        let insideEdge = [alpha(x: centre, y: margin + 2), alpha(x: centre, y: bodyMax - 2),
                          alpha(x: margin + 2, y: centre), alpha(x: bodyMax - 2, y: centre)]
        if let faint = insideEdge.first(where: { $0 < 250 }) {
            failures.append("the mask clipped the artwork's edges (faint alpha \(faint)); the icon is too small for its canvas")
        } else {
            print("  ok   the artwork reaches every edge of the rounded body")
        }

        if alpha(x: centre, y: centre) < 250 {
            failures.append("the centre of the icon is transparent or faint; the artwork did not cover the mask")
        } else {
            print("  ok   the artwork fills the mask")
        }
    } else {
        failures.append("could not rasterise the master render for inspection")
    }

    // 2. Orientation: the written icon must not be a flip of the supplied artwork.
    if let artwork, let sourceBands = rawBands(of: artwork, bandCount: 8),
       let readBack = loadImage(masterPNG.path),
       let renderedBands = rawBands(of: readBack, bandCount: 8) {
        let upright = correlation(renderedBands, sourceBands)
        let flipped = correlation(renderedBands, sourceBands.reversed())
        if upright > flipped && upright > 0.5 {
            print(String(format: "  ok   artwork orientation preserved (upright %.2f vs flipped %.2f)", upright, flipped))
        } else {
            failures.append(String(format: "the rendered icon does not follow the artwork's orientation (upright %.2f, flipped %.2f) — the artwork was probably flipped vertically", upright, flipped))
        }
    } else if artwork != nil {
        failures.append("could not compare the rendered icon against the source artwork")
    }

    // 3. The iconset must have made it into the .icns.
    if let data = try? Data(contentsOf: outputURL), data.count > 1000 {
        print("  ok   \(outputURL.lastPathComponent) written (\(data.count / 1024) KB)")
    } else {
        failures.append("the .icns is missing or implausibly small")
    }

    guard failures.isEmpty else { throw IconError.verificationFailed(failures) }
    print("icon verification passed")
}

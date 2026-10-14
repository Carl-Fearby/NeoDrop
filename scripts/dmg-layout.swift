#!/usr/bin/env swift
//
// Work out where the installer artwork expects the two icons to sit.
//
// The drag-and-drop background already has a NeoDrop app icon and an Applications folder painted
// into it, so the real ones have to land on top of them. Guessing those coordinates by eye gives a
// visibly doubled icon, so they are measured instead: threshold the artwork, find connected
// bright regions, and take the icon-shaped ones on the left and right.
//
// Usage: swift scripts/dmg-layout.swift <background.png> [--json]
//
// Prints the artwork size, the detected boxes, and the Finder values derived from them:
//   window size (points), icon size, and the two icon centres in view coordinates.

import Foundation
import CoreGraphics
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: dmg-layout.swift <background.png>\n".utf8))
    exit(2)
}
let backgroundPath = (arguments[1] as NSString).expandingTildeInPath

guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: backgroundPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write(Data("could not read \(backgroundPath)\n".utf8))
    exit(1)
}

// Analyse at half the artwork's resolution: plenty for locating a 500px icon, and four times less
// pixel pushing.
let width = image.width / 2
let height = image.height / 2
let scale = 2.0

var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
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
guard drew else {
    FileHandle.standardError.write(Data("could not rasterise the artwork\n".utf8))
    exit(1)
}

/// Luminance, using the usual perceptual weights.
func luminance(x: Int, y: Int) -> Double {
    let offset = (y * width + x) * 4
    return 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
}

// The backdrop is near-black navy; the icons, arrow and text are all much brighter. A fixed
// threshold is fine here and easy to reason about, since the artwork is dark by design.
let threshold = 105.0

var mask = [Bool](repeating: false, count: width * height)
for y in 0..<height {
    for x in 0..<width where luminance(x: x, y: y) > threshold {
        mask[y * width + x] = true
    }
}

// Connected components, 4-connectivity, iterative so a big region cannot blow the stack.
struct Component {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    var area = 0

    var centreX: Double { Double(minX + maxX) / 2 }
    var centreY: Double { Double(minY + maxY) / 2 }
    var boxWidth: Int { maxX - minX + 1 }
    var boxHeight: Int { maxY - minY + 1 }
}

var visited = [Bool](repeating: false, count: width * height)
var components: [Component] = []

for startY in 0..<height {
    for startX in 0..<width {
        let startIndex = startY * width + startX
        guard mask[startIndex], !visited[startIndex] else { continue }

        var component = Component()
        var stack = [startIndex]
        visited[startIndex] = true

        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            component.area += 1
            component.minX = min(component.minX, x)
            component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y)
            component.maxY = max(component.maxY, y)

            if x > 0, mask[index - 1], !visited[index - 1] { visited[index - 1] = true; stack.append(index - 1) }
            if x < width - 1, mask[index + 1], !visited[index + 1] { visited[index + 1] = true; stack.append(index + 1) }
            if y > 0, mask[index - width], !visited[index - width] { visited[index - width] = true; stack.append(index - width) }
            if y < height - 1, mask[index + width], !visited[index + width] { visited[index + width] = true; stack.append(index + width) }
        }
        components.append(component)
    }
}

// Icon-shaped means roughly square and a real presence on the canvas. This filters out the letters
// of the caption below and the thin arrow between the two icons.
let minimumHeight = Double(height) * 0.18
let icons = components.filter { component in
    let boxHeight = Double(component.boxHeight)
    let boxWidth = Double(component.boxWidth)
    guard boxHeight >= minimumHeight else { return false }
    let aspect = boxWidth / boxHeight
    return aspect > 0.75 && aspect < 1.45
}

guard let leftIcon = icons.filter({ $0.centreX < Double(width) * 0.5 }).max(by: { $0.area < $1.area }),
      let rightIcon = icons.filter({ $0.centreX > Double(width) * 0.5 }).max(by: { $0.area < $1.area }) else {
    FileHandle.standardError.write(Data("could not find two icon-shaped regions in the artwork\n".utf8))
    exit(1)
}

// Units, stated once so nothing downstream has to guess:
//   * the analysis ran at half the artwork's resolution, and that equals the window's size in
//     points, because a DMG window shows a 2x background at 1x
//   * so every coordinate below is already in view points, top-left origin — the same space
//     Finder's icon locations and the window bounds live in
//   * artwork pixels are only used when compositing, and are scaled back up by `scale`
let windowWidth = width
let windowHeight = height

func box(_ component: Component) -> [Int] {
    [component.minX, component.minY, component.boxWidth, component.boxHeight]
}

// Finder draws a file's icon centred on its location, at `icon_size` points. Sizing the real icon
// to the painted app icon is what makes it sit exactly over the painted one rather than beside it.
let appCentre = [leftIcon.minX + leftIcon.boxWidth / 2, leftIcon.minY + leftIcon.boxHeight / 2]
let applicationsCentre = [rightIcon.minX + rightIcon.boxWidth / 2, rightIcon.minY + rightIcon.boxHeight / 2]

// The icon box and the artwork drawn inside it are not the same thing: an app icon is designed on a
// 1024 canvas whose rounded-square body is 824 across, so the visible tile is only ~80% of the
// nominal size Finder was asked for. Setting `icon_size` to the painted tile's own size would
// therefore leave the painted icon peeking out all the way round — a doubled icon, which is the
// exact artefact this whole measurement exists to prevent. The nominal size is the painted tile
// divided by that body ratio. The painted tile is rarely square either (this one is 235x239), so it
// is the taller axis that has to be covered. The few points of slack absorb antialiasing on the
// painted edge.
let iconBodyRatio = 824.0 / 1024.0
let paintedIconSize = Int(max(leftIcon.boxWidth, leftIcon.boxHeight, rightIcon.boxWidth, rightIcon.boxHeight))
let iconSize = Int((Double(paintedIconSize) / iconBodyRatio).rounded(.up)) + 2

// The arrow sits between the two icons; the caption sits below them. Both are needed to check the
// real icons do not cover them.
let arrowBox = components
    .filter { $0.centreX > leftIcon.centreX && $0.centreX < rightIcon.centreX && $0.area > 100 }
    .max(by: { $0.area < $1.area })
    .map(box)

let captionTop = (0..<height).first { row in
    (0..<width).contains { column in luminance(x: column, y: row) > threshold }
        && Double(row) > Double(height) * 0.72
} ?? windowHeight

let layout: [String: Any] = [
    "artwork": ["width": image.width, "height": image.height, "scale": Int(scale)],
    "window": ["width": windowWidth, "height": windowHeight],
    "iconSize": iconSize,
    "iconBodyRatio": iconBodyRatio,
    "paintedIconSize": paintedIconSize,
    "appIcon": ["centre": appCentre, "box": box(leftIcon)],
    "applicationsIcon": ["centre": applicationsCentre, "box": box(rightIcon)],
    "arrow": arrowBox as Any,
    "captionTop": captionTop,
]

if arguments.contains("--json") {
    let data = try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    print()
} else {
    print("artwork:      \(image.width)x\(image.height) px at \(Int(scale))x")
    print("window:       \(windowWidth)x\(windowHeight) points")
    print("icon size:    \(iconSize) points (box; visible tile \(paintedIconSize) points)")
    print("app icon:     centre \(appCentre)  painted box xywh \(box(leftIcon))")
    print("applications: centre \(applicationsCentre)  painted box xywh \(box(rightIcon))")
    print("arrow box:    \(arrowBox.map(String.init(describing:)) ?? "not found")")
    print("caption top:  y=\(captionTop)")
    print("regions:      \(components.count) bright, \(icons.count) icon-shaped")
}

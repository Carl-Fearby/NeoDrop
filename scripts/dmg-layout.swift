#!/usr/bin/env swift
//
// Work out where the installer artwork expects the two icons to sit.
//
// The drag-and-drop background already has a NeoDrop app icon and an Applications folder painted
// into it, so the real ones have to land on top of them. Guessing those coordinates by eye gives a
// visibly doubled icon, so they are measured instead: threshold the artwork, find connected
// bright regions, and take the icon-shaped ones on the left and right.
//
// Usage: swift scripts/dmg-layout.swift <background.png> [--band <points>] [--json]
//
// Prints the artwork size, the detected boxes, and the Finder values derived from them:
//   window size (points), icon size, and the three icon centres in view coordinates.
//
// Every geometric claim this makes is checked against the artwork itself and fails loudly: the icons'
// boxes have to cover the painted tiles, their labels have to clear the caption, and the whole cell
// has to sit inside the window. A layout that only looks right in a comment is how the window ended
// up with four icons in it.

import Foundation
import CoreGraphics
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data(
        "usage: dmg-layout.swift <background.png> [--band <points>] [--json]\n".utf8))
    exit(2)
}
let backgroundPath = (arguments[1] as NSString).expandingTildeInPath

// The instructions file is shown in the window, so it needs a slot of its own. The art paints two
// icons across its whole width, so there is nowhere inside it that a third icon box fits: the slot
// has to be a band added beside the art. Its width is decided where the background is composed, and
// passing it in here means the slot is measured against the artwork actually being laid out.
var noticeBand = 0
if let index = arguments.firstIndex(of: "--band"), index + 1 < arguments.count {
    guard let parsed = Int(arguments[index + 1]), parsed > 0 else {
        FileHandle.standardError.write(Data("--band needs a positive width in points\n".utf8))
        exit(2)
    }
    noticeBand = parsed
}

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
    var brightest = 0.0

    var centreX: Double { Double(minX + maxX) / 2 }
    var centreY: Double { Double(minY + maxY) / 2 }
    var boxWidth: Int { maxX - minX + 1 }
    var boxHeight: Int { maxY - minY + 1 }
    var fullBox: [Int] { [minX, minY, maxX - minX + 1, maxY - minY + 1] }
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
            component.brightest = max(component.brightest, luminance(x: x, y: y))

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
// A painted tile is bright; the halo the art draws around it is not. Requiring real brightness stops
// a dim ring of glow — which crosses the base threshold at some scales and not others, depending on
// where the resampling lands — from being taken for the tile, which would inflate the icon size
// derived from it by a fifth and throw the whole layout out of step with the art.
let tileBrightness = 170.0
let icons = components.filter { component in
    let boxHeight = Double(component.boxHeight)
    let boxWidth = Double(component.boxWidth)
    guard boxHeight >= minimumHeight, component.brightest >= tileBrightness else { return false }
    let aspect = boxWidth / boxHeight
    return aspect > 0.75 && aspect < 1.45
}

// The two painted tiles, taken as the two largest icon-shaped bright regions and then put in order
// left to right. Splitting the canvas down the middle instead looks equivalent and is not: the art
// draws a ring of glow around each tile, and the ring's centre can fall on the other side of the
// midpoint from the tile's — at which point the tile is dropped and its own halo is measured in its
// place, which is how an icon size comes out a fifth too large.
let ranked = icons.sorted { $0.area > $1.area }
guard ranked.count >= 2 else {
    FileHandle.standardError.write(Data("could not find two icon-shaped regions in the artwork\n".utf8))
    exit(1)
}
let pair = [ranked[0], ranked[1]].sorted { $0.centreX < $1.centreX }
let leftIcon = pair[0]
let rightIcon = pair[1]

// Units, stated once so nothing downstream has to guess:
//   * the analysis ran at half the artwork's resolution, and that equals the window's size in
//     points, because a DMG window shows a 2x background at 1x
//   * so every coordinate below is already in view points, top-left origin — the same space
//     Finder's icon locations and the window bounds live in
//   * artwork pixels are only used when compositing, and are scaled back up by `scale`
let windowWidth = width
let windowHeight = height

func box(_ component: Component) -> [Int] {
    component.fullBox
}

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
/// Two integer boxes overlap. (The `overlaps` helper further down does the same for doubles.)
func boxesOverlap(_ a: [Int], _ b: [Int]) -> Bool {
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}

// The arrow is whatever sits in the gap between the two tiles. The tiles themselves have to be
// excluded by position, not just by centre: a tile whose measured centre drifts a couple of points
// past the icon's own centre would otherwise be picked as the arrow, and then the app icon would be
// measured against the arrow's box instead of its own tile.
let arrowBox = components
    .filter { component in
        guard component.centreX > leftIcon.centreX,
              component.centreX < rightIcon.centreX,
              component.area > 100,
              !boxesOverlap(component.fullBox, leftIcon.fullBox),
              !boxesOverlap(component.fullBox, rightIcon.fullBox) else { return false }
        return true
    }
    .max(by: { $0.area < $1.area })
    .map { $0.fullBox }

let captionTop = (0..<height).first { row in
    (0..<width).contains { column in luminance(x: column, y: row) > threshold }
        && Double(row) > Double(height) * 0.72
} ?? windowHeight

// ---------------------------------------------------------------------------------------------
// Where the three icons go

// Finder positions an icon's *cell* — the box plus the label under it — on the point it is given, so
// the box is drawn half a label higher than that point. Measured on macOS 26 by capturing a mounted
// window and locating the drawn icon: at icon size 254 the box centre landed 8-13pt below the
// recorded y, at three different y values. That is what make-dmg.py compensates for when writing the
// locations, and what the checks below reason about.
let labelHeight = 22            // a 13pt Finder label, measured the same way
let labelGap = 6                // the gap Finder leaves between the box and its label
let labelReservation = 140      // generous: Finder sizes the label to the text

// The painted tiles are ~200pt tall and the caption's ink starts 55pt below them, which leaves room
// for a Finder label only if the row of icons sits a little above the tiles' own centres: the tile
// only has to be covered by the box's *body* (the box inset ~10% a side), and that inset buys the
// few points needed. So the row is put as low as coverage allows — the labels then sit as far from
// the caption as they can — and the checks below fail if that is still not far enough.
let bodyHalf = Double(iconSize) * iconBodyRatio / 2
let coverageFloor = max(Double(leftIcon.maxY) - bodyHalf, Double(rightIcon.maxY) - bodyHalf)
let rowCentre = Int(coverageFloor.rounded(.up))
let appCentre = [leftIcon.minX + leftIcon.boxWidth / 2, rowCentre]
let applicationsCentre = [rightIcon.minX + rightIcon.boxWidth / 2, rowCentre]

func rect(_ centre: [Int], _ side: Double) -> [Double] {
    [Double(centre[0]) - side / 2, Double(centre[1]) - side / 2, side, side]
}
func inset(_ box: [Double], _ by: Double) -> [Double] {
    [box[0] + by, box[1] + by, box[2] - 2 * by, box[3] - 2 * by]
}
func overlaps(_ a: [Double], _ b: [Double]) -> Bool {
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}
func xywh(_ box: [Int]) -> [Double] {
    [Double(box[0]), Double(box[1]), Double(box[2]), Double(box[3])]
}
func labelBox(_ centre: [Int]) -> [Double] {
    [Double(centre[0]) - Double(labelReservation) / 2,
     Double(centre[1]) + Double(iconSize) / 2 + Double(labelGap),
     Double(labelReservation), Double(labelHeight)]
}

// The caption's whole ink box, not just its first row: the labels sit directly above it, so the check
// needs to know how far up it reaches and across where.
func inkBox(top: Int) -> [Double]? {
    var minX = Int.max, maxX = Int.min, maxY = Int.min
    for y in top..<height {
        for x in 0..<width where mask[y * width + x] {
            minX = min(minX, x); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX else { return nil }
    return [Double(minX), Double(top), Double(maxX - minX + 1), Double(maxY - top + 1)]
}
let captionBox = inkBox(top: captionTop) ?? [0, Double(captionTop), 0, 0]

// The instructions icon: centred in the band beside the art, on the same row as the other two.
let hasNoticeSlot = noticeBand > 0
let noticeCentre = [noticeBand / 2, rowCentre]
let noticeBox = hasNoticeSlot ? rect(noticeCentre, Double(iconSize)) : [0, 0, 0, 0]

// ---------------------------------------------------------------------------------------------
// Checks. Each of these is a way the rendered window can be wrong; a failure stops the build.

var problems: [String] = []
let placements: [(String, [Int], Int)] = hasNoticeSlot
    ? [("NeoDrop.app", appCentre, iconSize), ("Applications", applicationsCentre, iconSize),
       ("Read Me First.txt", noticeCentre, iconSize)]
    : [("NeoDrop.app", appCentre, iconSize), ("Applications", applicationsCentre, iconSize)]

for (name, centre, side) in placements {
    let cell = rect(centre, Double(side))
    // 1. An icon whose box hangs outside the content area makes Finder re-lay-out the entire window:
    //    measured on macOS 26 the icons then land ~92pt below where they were asked to go, on both
    //    axes at once. That mistake is what the previous build shipped.
    if cell[0] < 0 || cell[1] < 0
        || cell[0] + cell[2] > Double(windowWidth) || cell[1] + cell[3] > Double(windowHeight) {
        problems.append("\(name)'s \(side)pt box at \(centre) does not fit inside "
                        + "the \(windowWidth)x\(windowHeight) window")
    }
    // 2. The label is what lands on the caption when the row sits too low.
    let label = labelBox(centre)
    if overlaps(label, captionBox) {
        let overlap = min(label[1] + label[3], captionBox[1] + captionBox[3])
            - max(label[1], captionBox[1])
        if overlap > 2 {
            problems.append(String(format: "%@'s label would overlap the caption by %.0fpt", name, overlap))
        }
    }
    if label[1] + label[3] > Double(windowHeight) {
        problems.append("\(name)'s label would fall below the window's bottom edge")
    }
}

// 3. Each painted tile has to be covered by the *body* of the icon drawn over it, not by its nominal
//    box: the box is mostly transparent margin, so comparing the box with the tile would pass on an
//    image that shows the painted icon peeking out all round.
let bodyInset = Double(iconSize) * (1 - iconBodyRatio) / 2
for (name, centre, tile) in [("NeoDrop.app", appCentre, leftIcon), ("Applications", applicationsCentre, rightIcon)] {
    let body = inset(rect(centre, Double(iconSize)), bodyInset)
    let painted = xywh(box(tile))
    // Positive means the painted tile sticks out past the body, which is the doubled-icon artefact.
    let exposure = max(body[0] - painted[0], body[1] - painted[1],
                       (painted[0] + painted[2]) - (body[0] + body[2]),
                       (painted[1] + painted[3]) - (body[1] + body[3]))
    if exposure > 2 {
        problems.append(String(format: "%@'s icon would leave %.0fpt of the painted tile showing", name, exposure))
    }
    if let arrow = arrowBox, overlaps(body, xywh(arrow)) {
        problems.append("\(name)'s icon would cover the painted arrow")
    }
}

// 4. The band has to exist, be wide enough, and be genuinely empty: the whole reason for putting the
//    instructions beside the art instead of over it is that they land on plain background.
if hasNoticeSlot {
    if noticeBand < iconSize + 24 {
        problems.append("the \(noticeBand)pt band is too narrow for a \(iconSize)pt icon plus margins")
    }
    var ink = 0
    for y in 0..<height {
        for x in 0..<min(noticeBand, width) where mask[y * width + x] { ink += 1 }
    }
    if ink > 0 {
        problems.append("the band is not empty: \(ink) painted pixels lie under the instructions icon")
    }
    if leftIcon.minX < noticeBand {
        problems.append("the painted icons start at x=\(leftIcon.minX), inside the \(noticeBand)pt band")
    }
}

// A failed check still gets explained: the summary is printed first, then the failures, so a broken
// layout reports its numbers rather than just refusing to produce any.
let layout: [String: Any] = [
    "artwork": ["width": image.width, "height": image.height, "scale": Int(scale)],
    "window": ["width": windowWidth, "height": windowHeight],
    "iconSize": iconSize,
    "iconBodyRatio": iconBodyRatio,
    "paintedIconSize": paintedIconSize,
    "band": noticeBand,
    "rowCentre": rowCentre,
    "labelHeight": labelHeight,
    "labelGap": labelGap,
    "appIcon": ["centre": appCentre, "box": box(leftIcon), "label": labelBox(appCentre)],
    "applicationsIcon": ["centre": applicationsCentre, "box": box(rightIcon),
                         "label": labelBox(applicationsCentre)],
    "arrow": arrowBox as Any,
    "captionTop": captionTop,
    "captionBox": captionBox,
    "noticeIcon": [
        "centre": noticeCentre,
        "box": noticeBox,
        "label": labelBox(noticeCentre),
        "size": iconSize,
        "band": noticeBand,
    ],
]

if arguments.contains("--json"), problems.isEmpty {
    let data = try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    print()
} else if !arguments.contains("--json") {
    print("artwork:      \(image.width)x\(image.height) px at \(Int(scale))x")
    print("window:       \(windowWidth)x\(windowHeight) points")
    print("icon size:    \(iconSize) points (box; visible tile \(paintedIconSize) points)")
    print("app icon:     centre \(appCentre)  painted box xywh \(box(leftIcon))")
    print("applications: centre \(applicationsCentre)  painted box xywh \(box(rightIcon))")
    print("arrow box:    \(arrowBox.map(String.init(describing:)) ?? "not found")")
    print("caption top:  y=\(captionTop)")
    print("icon row:     centres at y=\(rowCentre); labels start y=\(rowCentre + iconSize / 2 + labelGap), "
          + "caption ink starts y=\(Int(captionBox[1]))")
    if hasNoticeSlot {
        print("notice slot:  centre \(noticeCentre) — a \(iconSize)pt icon centred in the \(noticeBand)pt band beside the art")
    } else {
        print("notice slot:  none (no --band given, so only the two painted icons are placed)")
    }
    print("regions:      \(components.count) bright, \(icons.count) icon-shaped")
}

if !problems.isEmpty {
    for problem in problems {
        FileHandle.standardError.write(Data("  FAIL \(problem)\n".utf8))
    }
    FileHandle.standardError.write(Data("dmg-layout: \(problems.count) geometry check(s) failed\n".utf8))
    exit(1)
}

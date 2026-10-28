#!/usr/bin/env swift
// Builds App/Assets.xcassets/AppIcon.appiconset from the two layers in design/icon/.
// Usage (from the repo root): swift scripts/make-app-icon.swift
//
// Follows Apple's macOS icon grid: a 1024 canvas with an 824-point rounded-rect body (corner radius
// 185.4) centered in it, a soft drop shadow, the background layer filling the body and the foreground
// artwork inset 40 points inside it.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let design = root.appending(path: "design/icon")
let output = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")

guard let foreground = NSImage(contentsOf: design.appending(path: "foreground.png")),
      let background = NSImage(contentsOf: design.appending(path: "background.png")) else {
    fatalError("design/icon/foreground.png and background.png are required")
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185.4 * s, yRadius: 185.4 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    background.draw(in: body)
    foreground.draw(in: body.insetBy(dx: 40 * s, dy: 40 * s))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appending(path: name))
        images.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(points)x\(points)"
            }
        """)
    }
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: output.appending(path: "Contents.json"))
try Data("""
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""".utf8).write(to: root.appending(path: "App/Assets.xcassets/Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")

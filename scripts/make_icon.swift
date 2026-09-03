#!/usr/bin/env swift
// Renders the app icon set with CoreGraphics so the repo carries no binary blobs.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data? {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return nil }

    // Rounded dark slate plate.
    let inset = dimension * 0.06
    let plate = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = dimension * 0.22
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [CGColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                  CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: dimension),
                                   end: CGPoint(x: dimension, y: 0),
                                   options: [])
    }
    context.restoreGState()

    // Disc.
    let center = CGPoint(x: dimension / 2, y: dimension / 2)
    let outerRadius = dimension * 0.30
    context.setFillColor(CGColor(red: 0.36, green: 0.60, blue: 0.98, alpha: 1))
    context.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.fillPath()

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.addArc(center: center, radius: outerRadius * 0.72, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.fillPath()

    context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
    context.addArc(center: center, radius: outerRadius * 0.26, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.fillPath()

    // Specular sweep across the disc.
    context.saveGState()
    context.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.clip()
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    context.fill(CGRect(x: 0, y: center.y + outerRadius * 0.30,
                        width: dimension, height: outerRadius * 0.34))
    context.restoreGState()

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: dimension, height: dimension)
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = drawIcon(size: size) else { continue }
    // iconutil only accepts this exact set of names; 1024 exists solely as 512@2x.
    if size <= 512 {
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(size/2)x\(size/2)@2x.png"))
    }
}
print("icon set written to \(outputDirectory)")

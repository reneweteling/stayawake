#!/usr/bin/env swift
// make-icon.swift: draws the StayAwake icon (a crescent moon with a small
// star on a deep ink squircle) at every size an .iconset needs, plus a 1024px
// PNG for the website. Run: swift scripts/make-icon.swift

import AppKit
import CoreGraphics

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
let root = repoRoot.hasPrefix("/") ? repoRoot : FileManager.default.currentDirectoryPath
let iconset = "\(root)/build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icon grid: the shape sits inside ~80% of the canvas.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(13, 21, 23))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient, ink to a deeper teal
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(28, 46, 50), color(8, 14, 16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // Crescent: a disc minus a shifted disc.
    let c = CGPoint(x: rect.midX - rect.width * 0.03, y: rect.midY)
    let r = rect.width * 0.30
    let crescent = CGMutablePath()
    crescent.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    let cut = CGPoint(x: c.x + r * 0.55, y: c.y + r * 0.35)
    let cr = r * 0.86
    crescent.addEllipse(in: CGRect(x: cut.x - cr, y: cut.y - cr, width: cr * 2, height: cr * 2))
    ctx.saveGState()
    ctx.addPath(crescent)
    ctx.clip(using: .evenOdd)
    let moon = CGGradient(colorsSpace: space, colors: [color(120, 230, 214), color(40, 160, 150)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(moon, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
    ctx.restoreGState()

    // A small four-point star next to the horn of the moon.
    let star = CGPoint(x: rect.midX + rect.width * 0.20, y: rect.midY + rect.height * 0.20)
    let sr = rect.width * 0.07
    let path = CGMutablePath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        let rr = i % 2 == 0 ? sr : sr * 0.28
        let p = CGPoint(x: star.x + cos(a) * rr, y: star.y + sin(a) * rr)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(color(243, 245, 242))
    ctx.fillPath()

    // Subtle top highlight
    let highlight = CGGradient(colorsSpace: space, colors: [color(255, 255, 255, 0.10), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in sizes {
    try! render(size).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "\(root)/build/icon-1024.png"))
print("✓ Wrote \(iconset)")

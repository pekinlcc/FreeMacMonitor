import AppKit
import CoreGraphics
import Foundation

// Generates an AppIcon.iconset directory with 10 PNG sizes ready for `iconutil -c icns`.
// Style: dark-green CRT background with 4 phosphor-green bar-chart bars and a subtle
// scanline overlay at larger sizes.  Ties visually to the Pip-Boy UI inside the panel.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift make_icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func render(size: Int) -> CGImage {
    let s  = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Rounded-rect clip per Apple icon spec (~22.37% of width)
    let corner = s * 0.2237
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: corner, cornerHeight: corner, transform: nil
    )
    ctx.addPath(bgPath); ctx.clip()

    // Background: vertical dark-green gradient
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.04, green: 0.09, blue: 0.04, alpha: 1),
        CGColor(red: 0.01, green: 0.03, blue: 0.01, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: s),
        end:   CGPoint(x: 0, y: 0),
        options: []
    )

    // Scanlines: only meaningful when there's room for them
    if size >= 128 {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
        let step = max(CGFloat(2), s / 96)
        var y: CGFloat = 0
        while y < s {
            ctx.fill(CGRect(x: 0, y: y, width: s, height: max(1, step * 0.33)))
            y += step
        }
    }

    // 4 vertical bars echoing CPU / MEM / GPU / DSK
    let heights: [CGFloat] = [0.32, 0.78, 0.46, 0.90]
    let margin = s * 0.20
    let availW = s - 2 * margin
    let availH = s - 2 * margin
    let gap    = availW * 0.10
    let barW   = (availW - gap * CGFloat(heights.count - 1)) / CGFloat(heights.count)
    let phosphor = CGColor(red: 0.22, green: 1.00, blue: 0.10, alpha: 1)

    for i in 0..<heights.count {
        let h    = heights[i] * availH
        let x    = margin + CGFloat(i) * (barW + gap)
        let rect = CGRect(x: x, y: margin, width: barW, height: h)

        if size >= 64 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: s * 0.028,
                color: CGColor(red: 0.22, green: 1.00, blue: 0.10, alpha: 0.8)
            )
            ctx.setFillColor(phosphor)
            ctx.fill(rect)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(phosphor)
            ctx.fill(rect)
        }
    }

    return ctx.makeImage()!
}

for (size, name) in sizes {
    let img = render(size: size)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
print("wrote \(sizes.count) PNGs → \(outDir.path)")

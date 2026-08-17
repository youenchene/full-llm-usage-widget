import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the 1024×1024 base app icon (a progress-gauge ring) to a PNG.
// Usage: swift Scripts/render_icon.swift <output.png>

let size = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024x1024.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let W = CGFloat(size)

// MARK: - Colors

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let background = rgb(0.11, 0.11, 0.13)
let track = rgb(1, 1, 1, 0.14)

let green = (CGFloat(0.20), CGFloat(0.78), CGFloat(0.35))
let orange = (CGFloat(1.0), CGFloat(0.62), CGFloat(0.04))
let red = (CGFloat(1.0), CGFloat(0.27), CGFloat(0.23))

func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat)
    -> (CGFloat, CGFloat, CGFloat) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

func arcColor(_ t: CGFloat) -> CGColor {
    let c = t < 0.5 ? mix(green, orange, t / 0.5) : mix(orange, red, (t - 0.5) / 0.5)
    return rgb(c.0, c.1, c.2)
}

// MARK: - Drawing

// Rounded-square background (macOS-style squircle).
let corner = W * 0.225
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: W),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
context.addPath(bgPath)
context.setFillColor(background)
context.fillPath()

// Gauge ring geometry.
let center = CGPoint(x: W / 2, y: W / 2)
let radius = W * 0.33
let thickness = W * 0.085
let progressFraction: CGFloat = 0.65
let startAngle = CGFloat.pi / 2                       // top
let sweep = 2 * CGFloat.pi * progressFraction

// Track (full circle).
context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
context.setStrokeColor(track)
context.setLineWidth(thickness)
context.strokePath()

// Progress arc, segmented for a smooth green→orange→red gradient.
let segments = 180
context.setLineWidth(thickness)
context.setLineCap(.round)
for i in 0..<segments {
    let t0 = CGFloat(i) / CGFloat(segments)
    let t1 = CGFloat(i + 1) / CGFloat(segments)
    context.setStrokeColor(arcColor((t0 + t1) / 2))
    context.addArc(
        center: center,
        radius: radius,
        startAngle: startAngle - sweep * t0,
        endAngle: startAngle - sweep * t1,
        clockwise: true
    )
    context.strokePath()
}

// Knob at the arc's leading edge.
let endAngle = startAngle - sweep
let knobCenter = CGPoint(
    x: center.x + radius * cos(endAngle),
    y: center.y + radius * sin(endAngle)
)
context.setFillColor(rgb(1, 1, 1))
context.addEllipse(in: CGRect(x: knobCenter.x - thickness / 2, y: knobCenter.y - thickness / 2,
                              width: thickness, height: thickness))
context.fillPath()

// MARK: - Write PNG

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("failed to render image\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: outputPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("failed to create destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("failed to write PNG\n".utf8))
    exit(1)
}
print("Wrote \(outputPath)")

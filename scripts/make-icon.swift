// Renders the Stint app icon ("Sweep": a ring 70% filled on the accent blue).
// Usage: swift scripts/make-icon.swift <out.png> [size] [--mac]
//   default: opaque full-bleed square (iOS masks the corners itself)
//   --mac:   macOS grid: 824/1024 rounded tile, transparent margin, drop shadow
import AppKit

let args = CommandLine.arguments
let out = args[1]
let size = args.count > 2 ? Int(args[2])! : 1024
let mac = args.contains("--mac")

let accent = CGColor(srgbRed: 0, green: 0x64 / 255, blue: 0xD2 / 255, alpha: 1)
let s = CGFloat(size) / 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.scaleBy(x: s, y: s)

// Tile: whole canvas on iOS; Apple's macOS grid (824 px tile, 185.4 px corners) on Mac.
var tile: CGFloat = 1024
if mac {
    tile = 824
    let rect = CGRect(x: 100, y: 100, width: tile, height: tile)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil))
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()
} else {
    ctx.setFillColor(accent)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
}

// Ring, drawn in tile units (1024 = tile edge) so both variants match the artboard.
let k = tile / 1024
let c = CGPoint(x: 512, y: 512), r = 290 * k
ctx.setLineWidth(104 * k)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineCap(.round)
let top = CGFloat.pi / 2
ctx.addArc(center: c, radius: r, startAngle: top, endAngle: top - 0.7 * 2 * .pi, clockwise: true)
ctx.strokePath()

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))

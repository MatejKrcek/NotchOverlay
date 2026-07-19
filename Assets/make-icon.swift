// Generátor ikony appky — vykreslí AppIcon.png (1024×1024) přes CoreGraphics.
// Spuštění: swift Assets/make-icon.swift (nebo swiftc; výstup vedle skriptu).
// .icns se pak skládá přes sips + iconutil, viz Assets/build-icon.sh.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// Apple template: obsah ikony je squircle ~824 pt na 1024 pt plátně.
let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 186, cornerHeight: 186, transform: nil)

// --- pozadí: tmavý vertikální gradient ---
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [rgba(40, 44, 56), rgba(16, 17, 23)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// jemná záře za pillem, ať střed žije
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [rgba(90, 140, 255, 0.22), rgba(90, 140, 255, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

// --- notch: černý výřez srostlý s horní hranou squirclu ---
// (CG má počátek vlevo dole → horní hrana je y=924)
let notchW = 380.0, notchH = 130.0, notchR = 44.0
let notch = CGMutablePath()
notch.move(to: CGPoint(x: 512 - notchW/2, y: 924))
notch.addLine(to: CGPoint(x: 512 - notchW/2, y: 924 - notchH + notchR))
notch.addArc(tangent1End: CGPoint(x: 512 - notchW/2, y: 924 - notchH),
             tangent2End: CGPoint(x: 512 - notchW/2 + notchR, y: 924 - notchH), radius: notchR)
notch.addLine(to: CGPoint(x: 512 + notchW/2 - notchR, y: 924 - notchH))
notch.addArc(tangent1End: CGPoint(x: 512 + notchW/2, y: 924 - notchH),
             tangent2End: CGPoint(x: 512 + notchW/2, y: 924 - notchH + notchR), radius: notchR)
notch.addLine(to: CGPoint(x: 512 + notchW/2, y: 924))
notch.closeSubpath()
ctx.addPath(notch)
ctx.setFillColor(rgba(0, 0, 0))
ctx.fillPath()

// --- island pill ---
let pillW = 580.0, pillH = 240.0
let pillRect = CGRect(x: 512 - pillW/2, y: 470 - pillH/2, width: pillW, height: pillH)
let pill = CGPath(roundedRect: pillRect, cornerWidth: pillH/2, cornerHeight: pillH/2, transform: nil)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 60, color: rgba(0, 0, 0, 0.55))
ctx.addPath(pill)
ctx.setFillColor(rgba(5, 5, 8))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// tenký světlý okraj pillu
ctx.addPath(CGPath(roundedRect: pillRect.insetBy(dx: 3, dy: 3),
                   cornerWidth: pillH/2 - 3, cornerHeight: pillH/2 - 3, transform: nil))
ctx.setStrokeColor(rgba(255, 255, 255, 0.14))
ctx.setLineWidth(6)
ctx.strokePath()

// --- stavové tečky: modrá (pracuje), zelená (hotovo), oranžová (akce) ---
let dotR = 46.0, dotGap = 150.0
let dotColors = [rgba(64, 156, 255), rgba(48, 209, 88), rgba(255, 159, 10)]
for (i, color) in dotColors.enumerated() {
    let cx = 512 + (Double(i) - 1) * dotGap
    let rect = CGRect(x: cx - dotR, y: 470 - dotR, width: dotR * 2, height: dotR * 2)
    ctx.setShadow(offset: .zero, blur: 34, color: color.copy(alpha: 0.8))
    ctx.setFillColor(color)
    ctx.fillEllipse(in: rect)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // drobný odlesk, ať tečky nejsou placaté
    ctx.setFillColor(rgba(255, 255, 255, 0.35))
    ctx.fillEllipse(in: CGRect(x: cx - dotR * 0.42, y: 470 + dotR * 0.1,
                               width: dotR * 0.8, height: dotR * 0.55))
}

// --- vnitřní odlesk horní hrany squirclu ---
ctx.addPath(squircle)
ctx.setStrokeColor(rgba(255, 255, 255, 0.07))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "Assets/AppIcon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("OK -> \(out.path)")

import AppKit
import Metal

/// Sprity počasí kreslené procedurálně do jedné textury (žádné assety).
///
/// Dva druhy dlaždic:
/// - „materiál" (mode 0 v shaderu): kanály nejsou barva, ale vlastnosti —
///   R = stínování, G = vzdálenost od okraje (0 okraj … 1 střed),
///   B = odlesk / prosvítání, A = tvar. Barvu dodá instance (tint),
///   takže jeden list poslouží pro všechny podzimní barvy a okraje může
///   shader „zahnědnout" (vadnutí okvětních lístků).
/// - „barva" (mode 1): hotový premultiplied RGBA obrázek (dýně, duchové, kvítek).
enum Sprite: Int, CaseIterable {
    case flakeSoft, flakeFluffy, flakeCrystal, sparkle, dot, glow
    case leafMaple, leafOval, leafOak, leafBirch
    case petal, petalCurled
    case bead, streak
    case pumpkin, pumpkinWink
    case ghostBoo, ghostHalloween, ghostTrick, ghostBrrr
    case flower
}

struct SpriteUV {
    var u0: Float = 0, v0: Float = 0, u1: Float = 0, v1: Float = 0
    /// Přirozená velikost v bodech (u barevných spritů), u materiálů poměr stran.
    var w: Float = 1, h: Float = 1
}

enum WeatherAtlas {
    /// Rozlišení kreslení: 2 px na bod (Retina).
    static let scale: CGFloat = 2

    struct Built {
        let texture: MTLTexture
        let uv: [SpriteUV]
    }

    /// Nejmenší atlas, do kterého se všechno vejde (512² ≈ 1,4 MB s mipmapami).
    static func build(device: MTLDevice, queue: MTLCommandQueue) -> Built? {
        for size in [512, 1024] {
            if let b = build(device: device, queue: queue, size: size) { return b }
        }
        return nil
    }

    private static func build(device: MTLDevice, queue: MTLCommandQueue, size: Int) -> Built? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var complete = true
        var uv = [SpriteUV](repeating: SpriteUV(), count: Sprite.allCases.count)
        var packer = ShelfPacker(size: size, pad: 6)

        func place(_ s: Sprite, _ w: Int, _ h: Int, ptW: Float, ptH: Float, _ rgba: [UInt8]) {
            guard let (x, y) = packer.place(w, h) else { complete = false; return }
            for row in 0..<h {
                let src = row * w * 4
                let dst = ((y + row) * size + x) * 4
                pixels.replaceSubrange(dst..<(dst + w * 4), with: rgba[src..<(src + w * 4)])
            }
            let f = Float(size)
            uv[s.rawValue] = SpriteUV(u0: Float(x) / f, v0: Float(y) / f,
                                      u1: Float(x + w) / f, v1: Float(y + h) / f, w: ptW, h: ptH)
        }

        // --- materiály ---
        let m64 = 64
        place(.flakeSoft, m64, m64, ptW: 1, ptH: 1, Material.flakeSoft(m64))
        place(.flakeFluffy, m64, m64, ptW: 1, ptH: 1, Material.flakeFluffy(m64))
        place(.flakeCrystal, 96, 96, ptW: 1, ptH: 1, Material.flakeCrystal(96))
        place(.sparkle, m64, m64, ptW: 1, ptH: 1, Material.sparkle(m64))
        place(.dot, 32, 32, ptW: 1, ptH: 1, Material.dot(32))
        place(.glow, m64, m64, ptW: 1, ptH: 1, Material.glow(m64))
        place(.leafMaple, 96, 96, ptW: 1, ptH: 1, Material.leafMaple(96))
        place(.leafOval, 96, 96, ptW: 1, ptH: 1, Material.leafLobed(96, lobes: 0, amp: 0, width: 0.36))
        place(.leafOak, 96, 96, ptW: 1, ptH: 1, Material.leafLobed(96, lobes: 3.5, amp: 0.34, width: 0.40))
        place(.leafBirch, 96, 96, ptW: 1, ptH: 1, Material.leafLobed(96, lobes: 9, amp: 0.06, width: 0.44))
        place(.petal, 80, 80, ptW: 1, ptH: 1, Material.petal(80, curl: 0))
        place(.petalCurled, 80, 80, ptW: 1, ptH: 1, Material.petal(80, curl: 1))
        place(.bead, m64, m64, ptW: 1, ptH: 1, Material.bead(m64))
        place(.streak, 16, 96, ptW: 1, ptH: 6, Material.streak(16, 96))

        // --- barevné ---
        place(.pumpkin, 64, 56, ptW: 32, ptH: 28, ColorArt.pumpkin(64, 56, wink: false))
        place(.pumpkinWink, 64, 56, ptW: 32, ptH: 28, ColorArt.pumpkin(64, 56, wink: true))
        let signs: [(Sprite, String)] = [(.ghostBoo, "BOO!"), (.ghostHalloween, "Happy Halloween"),
                                         (.ghostTrick, "Trick or treat"), (.ghostBrrr, "Brrr…")]
        for (s, text) in signs {
            place(s, 112, 128, ptW: 56, ptH: 64, ColorArt.ghost(112, 128, sign: text))
        }
        place(.flower, 72, 104, ptW: 18, ptH: 26, ColorArt.flower(72, 104))
        guard complete else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return Built(texture: tex, uv: uv)
    }
}

/// Jednoduché řádkové balení dlaždic.
private struct ShelfPacker {
    let size: Int
    let pad: Int
    var x = 0, y = 0, rowH = 0

    init(size: Int, pad: Int) {
        self.size = size
        self.pad = pad
        x = pad
        y = pad
    }

    mutating func place(_ w: Int, _ h: Int) -> (Int, Int)? {
        if x + w + pad > size {
            x = pad
            y += rowH + pad
            rowH = 0
        }
        guard y + h + pad <= size else { return nil }
        let at = (x, y)
        x += w + pad
        rowH = max(rowH, h)
        return at
    }
}

// MARK: - Kreslení do šedotónových kanálů

/// Šedotónové plátno w×h; kreslí se v jednotkových souřadnicích -1…1 (y nahoru).
private func gray(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h)
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.scaleBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.setShouldAntialias(true)
        draw(ctx)
    }
    return buf
}

/// Vzdálenost od okraje tvaru (chamfer 3-4), normalizovaná na 0…1.
private func edgeDistance(_ a: [UInt8], _ w: Int, _ h: Int, reach: Float) -> [UInt8] {
    let inf: Float = 1e6
    var d = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { d[i] = a[i] > 127 ? inf : 0 }
    func at(_ x: Int, _ y: Int) -> Float {
        (x < 0 || y < 0 || x >= w || y >= h) ? 0 : d[y * w + x]
    }
    for y in 0..<h {
        for x in 0..<w where d[y * w + x] > 0 {
            var v = d[y * w + x]
            v = min(v, at(x - 1, y) + 1)
            v = min(v, at(x, y - 1) + 1)
            v = min(v, at(x - 1, y - 1) + 1.4142)
            v = min(v, at(x + 1, y - 1) + 1.4142)
            d[y * w + x] = v
        }
    }
    for y in stride(from: h - 1, through: 0, by: -1) {
        for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            var v = d[y * w + x]
            v = min(v, at(x + 1, y) + 1)
            v = min(v, at(x, y + 1) + 1)
            v = min(v, at(x + 1, y + 1) + 1.4142)
            v = min(v, at(x - 1, y + 1) + 1.4142)
            d[y * w + x] = v
        }
    }
    var maxD: Float = 1
    for v in d where v < inf { maxD = max(maxD, v) }
    let norm = maxD * reach
    return d.map { UInt8(max(0, min(255, $0 / norm * 255))) }
}

private func interleave(r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: a.count * 4)
    for i in 0..<a.count {
        out[i * 4] = r[i]
        out[i * 4 + 1] = g[i]
        out[i * 4 + 2] = b[i]
        out[i * 4 + 3] = a[i]
    }
    return out
}

private func fillGray(_ ctx: CGContext, _ v: CGFloat, alpha: CGFloat = 1) {
    ctx.setFillColor(gray: v, alpha: alpha)
}

/// Měkký radiální gradient (bílá uprostřed → černá na okraji).
private func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, inner: CGFloat, outer: CGFloat,
                    innerFrac: CGFloat = 0) {
    let space = CGColorSpaceCreateDeviceGray()
    let comps: [CGFloat] = [inner, 1, inner, 1, outer, 1]
    guard let g = CGGradient(colorSpace: space, colorComponents: comps,
                             locations: [0, innerFrac, 1], count: 3) else { return }
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [])
}

private enum Material {
    static func flakeSoft(_ n: Int) -> [UInt8] {
        // měkký kotouč; R slabě tmavší k okraji, aby vločka byla vidět i na bílém
        let a = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0, innerFrac: 0.38) }
        let r = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0.74, innerFrac: 0.3) }
        let g = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0) }
        let b = [UInt8](repeating: 0, count: n * n)
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func flakeFluffy(_ n: Int) -> [UInt8] {
        let blobs: [(CGFloat, CGFloat, CGFloat)] = [(-0.22, 0.12, 0.55), (0.25, 0.18, 0.5),
                                                    (0.02, -0.25, 0.55), (0.05, 0.05, 0.62)]
        let a = gray(n, n) { ctx in
            ctx.setBlendMode(.lighten)
            for (x, y, rad) in blobs {
                radial(ctx, center: CGPoint(x: x, y: y), radius: rad + 0.25, inner: 1, outer: 0, innerFrac: 0.45)
            }
        }
        let r = gray(n, n) { ctx in
            fillGray(ctx, 0.7)
            ctx.fill(CGRect(x: -1, y: -1, width: 2, height: 2))
            ctx.setBlendMode(.lighten)
            for (x, y, rad) in blobs {
                radial(ctx, center: CGPoint(x: x + 0.05, y: y + 0.08), radius: rad, inner: 1, outer: 0.7)
            }
        }
        let g = edgeDistance(a, n, n, reach: 0.8)
        let b = [UInt8](repeating: 0, count: n * n)
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func flakeCrystal(_ n: Int) -> [UInt8] {
        let a = gray(n, n) { ctx in
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineCap(.round)
            for k in 0..<6 {
                let ang = CGFloat(k) * .pi / 3
                let dx = cos(ang), dy = sin(ang)
                ctx.setLineWidth(0.1)
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: dx * 0.86, y: dy * 0.86))
                ctx.strokePath()
                ctx.setLineWidth(0.07)
                for t: CGFloat in [0.42, 0.64] {
                    let px = dx * t, py = dy * t
                    let len: CGFloat = 0.24 * (1.1 - t)
                    for side: CGFloat in [-1, 1] {
                        let a2 = ang + side * 0.8
                        ctx.move(to: CGPoint(x: px, y: py))
                        ctx.addLine(to: CGPoint(x: px + cos(a2) * len, y: py + sin(a2) * len))
                        ctx.strokePath()
                    }
                }
            }
            radial(ctx, center: .zero, radius: 0.22, inner: 1, outer: 0, innerFrac: 0.5)
        }
        let r = gray(n, n) { ctx in
            fillGray(ctx, 0.75)
            ctx.fill(CGRect(x: -1, y: -1, width: 2, height: 2))
            ctx.setBlendMode(.lighten)
            radial(ctx, center: .zero, radius: 0.9, inner: 1, outer: 0.8)
        }
        let g = edgeDistance(a, n, n, reach: 1)
        let b = [UInt8](repeating: 0, count: n * n)
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func sparkle(_ n: Int) -> [UInt8] {
        let a = gray(n, n) { ctx in
            radial(ctx, center: .zero, radius: 0.32, inner: 1, outer: 0)
            ctx.setBlendMode(.lighten)
            for (w, h) in [(CGFloat(0.09), CGFloat(1.0)), (1.0, 0.09)] {
                let space = CGColorSpaceCreateDeviceGray()
                let grad = CGGradient(colorSpace: space, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2)!
                ctx.saveGState()
                ctx.scaleBy(x: w, y: h)
                ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
                ctx.restoreGState()
            }
        }
        let full = [UInt8](repeating: 255, count: n * n)
        let zero = [UInt8](repeating: 0, count: n * n)
        return interleave(r: full, g: zero, b: zero, a: a)
    }

    static func dot(_ n: Int) -> [UInt8] {
        let a = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0, innerFrac: 0.6) }
        let r = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0.7, innerFrac: 0.4) }
        let g = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0) }
        let b = [UInt8](repeating: 0, count: n * n)
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func glow(_ n: Int) -> [UInt8] {
        let a = gray(n, n) { ctx in
            let space = CGColorSpaceCreateDeviceGray()
            let grad = CGGradient(colorSpace: space, colorComponents: [1, 1, 0.45, 1, 0.12, 1, 0, 1],
                                  locations: [0, 0.25, 0.6, 1], count: 4)!
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        }
        let full = [UInt8](repeating: 255, count: n * n)
        let zero = [UInt8](repeating: 0, count: n * n)
        return interleave(r: full, g: zero, b: zero, a: a)
    }

    /// Obrys listu: poloviční šířka podél výšky, volitelně s laloky.
    private static func leafPath(lobes: CGFloat, amp: CGFloat, width: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let steps = 48
        var right: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)          // 0 = stopka, 1 = špička
            let y = -0.72 + t * 1.62
            var w = width * pow(sin(.pi * min(1, t * 1.0)), 0.75) * (1 - 0.25 * t)
            if lobes > 0 { w *= 1 - amp + amp * abs(cos(t * .pi * lobes)) }
            right.append(CGPoint(x: w, y: y))
        }
        p.move(to: right[0])
        for pt in right.dropFirst() { p.addLine(to: pt) }
        for pt in right.reversed() { p.addLine(to: CGPoint(x: -pt.x, y: pt.y)) }
        p.closeSubpath()
        return p
    }

    private static func veins(_ ctx: CGContext, maple: Bool) {
        ctx.setStrokeColor(gray: 0.55, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.035)
        ctx.move(to: CGPoint(x: 0, y: -0.95))
        ctx.addLine(to: CGPoint(x: 0, y: 0.85))
        ctx.strokePath()
        ctx.setLineWidth(0.022)
        if maple {
            for ang: CGFloat in [0.5, 1.15, -0.5, -1.15] {
                ctx.move(to: CGPoint(x: 0, y: -0.35))
                ctx.addLine(to: CGPoint(x: sin(ang) * 0.85, y: -0.35 + cos(ang) * 0.75))
                ctx.strokePath()
            }
        } else {
            for i in 0..<5 {
                let y = -0.45 + CGFloat(i) * 0.28
                for side: CGFloat in [-1, 1] {
                    ctx.move(to: CGPoint(x: 0, y: y))
                    ctx.addLine(to: CGPoint(x: side * 0.3, y: y + 0.22))
                    ctx.strokePath()
                }
            }
        }
    }

    private static func leafChannels(_ n: Int, shape: CGPath, stem: Bool, maple: Bool) -> [UInt8] {
        let a = gray(n, n) { ctx in
            fillGray(ctx, 1)
            ctx.addPath(shape)
            ctx.fillPath()
            if stem {
                ctx.setStrokeColor(gray: 1, alpha: 1)
                ctx.setLineWidth(0.05)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 0, y: -0.7))
                ctx.addLine(to: CGPoint(x: 0.04, y: -0.98))
                ctx.strokePath()
            }
        }
        let r = gray(n, n) { ctx in
            // jemný přechod: jedna polovina listu světlejší (zakřivení), žilky tmavší
            let space = CGColorSpaceCreateDeviceGray()
            let grad = CGGradient(colorSpace: space, colorComponents: [0.78, 1, 1.0, 1], locations: [0, 1], count: 2)!
            ctx.drawLinearGradient(grad, start: CGPoint(x: -0.6, y: -0.6), end: CGPoint(x: 0.6, y: 0.7), options: [])
            veins(ctx, maple: maple)
        }
        let g = edgeDistance(a, n, n, reach: 0.9)
        let b = gray(n, n) { radial($0, center: CGPoint(x: 0.18, y: 0.25), radius: 0.7, inner: 0.55, outer: 0) }
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func leafLobed(_ n: Int, lobes: CGFloat, amp: CGFloat, width: CGFloat) -> [UInt8] {
        leafChannels(n, shape: leafPath(lobes: lobes, amp: amp, width: width), stem: true, maple: false)
    }

    static func leafMaple(_ n: Int) -> [UInt8] {
        // pravá polovina javorového listu (y nahoru), zrcadlí se
        let half: [(CGFloat, CGFloat)] = [
            (0, 0.95), (0.1, 0.6), (0.3, 0.72), (0.26, 0.38), (0.64, 0.52), (0.55, 0.26),
            (0.92, 0.14), (0.56, -0.04), (0.64, -0.26), (0.3, -0.2), (0.16, -0.42), (0.04, -0.4),
        ]
        let p = CGMutablePath()
        p.move(to: CGPoint(x: half[0].0, y: half[0].1))
        for (x, y) in half.dropFirst() { p.addLine(to: CGPoint(x: x, y: y)) }
        for (x, y) in half.reversed() { p.addLine(to: CGPoint(x: -x, y: y)) }
        p.closeSubpath()
        return leafChannels(n, shape: p, stem: true, maple: true)
    }

    static func petal(_ n: Int, curl: CGFloat) -> [UInt8] {
        // obvejčitý lístek se zářezem na špičce; „lžička" = stín z jedné strany
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 0, y: -0.9))
        shape.addCurve(to: CGPoint(x: 0.62, y: 0.55), control1: CGPoint(x: 0.42, y: -0.7),
                       control2: CGPoint(x: 0.72, y: 0.1))
        shape.addCurve(to: CGPoint(x: 0.0, y: 0.72), control1: CGPoint(x: 0.5, y: 0.92),
                       control2: CGPoint(x: 0.14, y: 0.92))
        shape.addCurve(to: CGPoint(x: -0.62, y: 0.55), control1: CGPoint(x: -0.14, y: 0.92),
                       control2: CGPoint(x: -0.5, y: 0.92))
        shape.addCurve(to: CGPoint(x: 0, y: -0.9), control1: CGPoint(x: -0.72, y: 0.1),
                       control2: CGPoint(x: -0.42, y: -0.7))
        shape.closeSubpath()
        let a = gray(n, n) { ctx in
            ctx.saveGState()
            if curl > 0 { ctx.scaleBy(x: 0.78, y: 1) }
            fillGray(ctx, 1)
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
        }
        let r = gray(n, n) { ctx in
            let space = CGColorSpaceCreateDeviceGray()
            let grad = CGGradient(colorSpace: space, colorComponents: [0.72, 1, 0.97, 1, 0.86, 1],
                                  locations: [0, 0.55, 1], count: 3)!
            ctx.drawLinearGradient(grad, start: CGPoint(x: -0.7, y: 0), end: CGPoint(x: 0.7, y: 0), options: [])
            // tmavší u báze (kde lístek přirůstal)
            ctx.setBlendMode(.multiply)
            let g2 = CGGradient(colorSpace: space, colorComponents: [0.8, 1, 1, 1], locations: [0, 1], count: 2)!
            ctx.drawLinearGradient(g2, start: CGPoint(x: 0, y: -0.9), end: CGPoint(x: 0, y: -0.2), options: [])
        }
        let g = edgeDistance(a, n, n, reach: 0.85)
        let b = gray(n, n) { ctx in
            // odlesk podél jedné strany lžičky + prosvítání u špičky
            ctx.saveGState()
            ctx.rotate(by: -0.35)
            ctx.scaleBy(x: 0.25, y: 0.7)
            radial(ctx, center: CGPoint(x: 1.2, y: 0.2), radius: 1, inner: 0.9, outer: 0)
            ctx.restoreGState()
            ctx.setBlendMode(.lighten)
            radial(ctx, center: CGPoint(x: 0, y: 0.55), radius: 0.55, inner: 0.35, outer: 0)
        }
        return interleave(r: r, g: g, b: b, a: a)
    }

    static func bead(_ n: Int) -> [UInt8] {
        // kapka na skle: tmavší lem (lom světla), světlé jádro, ostrý odlesk vlevo nahoře
        let a = gray(n, n) { ctx in
            radial(ctx, center: .zero, radius: 0.98, inner: 1, outer: 0, innerFrac: 0.82)
        }
        let r = gray(n, n) { ctx in
            let space = CGColorSpaceCreateDeviceGray()
            let grad = CGGradient(colorSpace: space, colorComponents: [0.95, 1, 0.85, 1, 0.42, 1],
                                  locations: [0, 0.6, 1], count: 3)!
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 0.05, y: -0.12), startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [])
        }
        let g = gray(n, n) { radial($0, center: .zero, radius: 1, inner: 1, outer: 0) }
        let b = gray(n, n) { ctx in
            radial(ctx, center: CGPoint(x: -0.32, y: 0.36), radius: 0.26, inner: 1, outer: 0, innerFrac: 0.35)
            ctx.setBlendMode(.lighten)
            ctx.saveGState()
            ctx.scaleBy(x: 1, y: 0.4)
            radial(ctx, center: CGPoint(x: 0.1, y: -1.6), radius: 0.6, inner: 0.45, outer: 0)
            ctx.restoreGState()
        }
        return interleave(r: r, g: g, b: b, a: a)
    }

    /// Dešťová čára: hlava dole (směr pohybu), ocas nahoře slábne.
    static func streak(_ w: Int, _ h: Int) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: w * h)
        var g = [UInt8](repeating: 0, count: w * h)
        for py in 0..<h {
            let v = (Double(py) + 0.5) / Double(h)            // 0 nahoře … 1 dole
            let tail = pow(v, 1.6)
            let head = 1 - max(0, min(1, (v - 0.9) / 0.1))
            for px in 0..<w {
                let u = (Double(px) + 0.5) / Double(w) * 2 - 1
                let across = exp(-u * u * 5)
                a[py * w + px] = UInt8(max(0, min(255, across * tail * head * 255)))
                g[py * w + px] = UInt8(max(0, min(255, across * 255)))
            }
        }
        let full = [UInt8](repeating: 255, count: w * h)
        let b = [UInt8](repeating: 0, count: w * h)
        return interleave(r: full, g: g, b: b, a: a)
    }
}

// MARK: - Barevné sprity

private enum ColorArt {
    /// RGBA premultiplied; kreslí se v bodech (0,0 vlevo dole), plátno je 2× větší.
    static func canvas(_ w: Int, _ h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: WeatherAtlas.scale, y: WeatherAtlas.scale)
            draw(ctx, CGFloat(w) / WeatherAtlas.scale, CGFloat(h) / WeatherAtlas.scale)
        }
        return buf
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    static func pumpkin(_ w: Int, _ h: Int, wink: Bool) -> [UInt8] {
        canvas(w, h) { ctx, W, H in
            let cx = W / 2, cy = H * 0.44
            let bw = W * 0.86, bh = H * 0.7
            // žebra: překrývající se elipsy, tmavší po stranách
            let ribs: [(CGFloat, CGFloat, CGColor)] = [
                (-0.3, 0.5, rgb(0.78, 0.33, 0.06)), (0.3, 0.5, rgb(0.78, 0.33, 0.06)),
                (-0.14, 0.62, rgb(0.9, 0.44, 0.1)), (0.14, 0.62, rgb(0.9, 0.44, 0.1)),
                (0, 0.56, rgb(0.97, 0.52, 0.14)),
            ]
            for (off, wf, col) in ribs {
                let rw = bw * wf
                ctx.setFillColor(col)
                ctx.fillEllipse(in: CGRect(x: cx + off * bw - rw / 2, y: cy - bh / 2, width: rw, height: bh))
            }
            // stopka
            ctx.setFillColor(rgb(0.33, 0.27, 0.12))
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: cx - 2, y: cy + bh / 2 - 2))
            stem.addLine(to: CGPoint(x: cx + 2.2, y: cy + bh / 2 - 2))
            stem.addLine(to: CGPoint(x: cx + 3.6, y: cy + bh / 2 + 4.5))
            stem.addLine(to: CGPoint(x: cx + 0.8, y: cy + bh / 2 + 5))
            stem.closeSubpath()
            ctx.addPath(stem)
            ctx.fillPath()
            // obličej: svítící vnitřek
            let glow = rgb(1.0, 0.86, 0.32)
            ctx.setFillColor(glow)
            func tri(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
                ctx.move(to: CGPoint(x: x - s, y: y - s * 0.6))
                ctx.addLine(to: CGPoint(x: x + s, y: y - s * 0.6))
                ctx.addLine(to: CGPoint(x: x, y: y + s * 0.8))
                ctx.closePath()
                ctx.fillPath()
            }
            tri(cx - 6, cy + 3, 3.4)
            if wink {
                ctx.setStrokeColor(glow)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: cx + 3, y: cy + 3))
                ctx.addLine(to: CGPoint(x: cx + 9, y: cy + 3))
                ctx.strokePath()
            } else {
                tri(cx + 6, cy + 3, 3.4)
            }
            let mouth = CGMutablePath()
            let my = cy - 5.5
            mouth.move(to: CGPoint(x: cx - 9, y: my + 2))
            let teeth: [(CGFloat, CGFloat)] = [(-6, -1), (-3.5, 0.5), (-1, -1.6), (1.5, 0.5), (4, -1), (6.5, 0.6), (9, 2)]
            for (dx, dy) in teeth { mouth.addLine(to: CGPoint(x: cx + dx, y: my + dy)) }
            mouth.addQuadCurve(to: CGPoint(x: cx - 9, y: my + 2), control: CGPoint(x: cx, y: my - 7))
            ctx.addPath(mouth)
            ctx.fillPath()
        }
    }

    static func ghost(_ w: Int, _ h: Int, sign: String) -> [UInt8] {
        canvas(w, h) { ctx, W, H in
            // cedulka na tyčce vpravo nahoře
            let boardW: CGFloat = W * 0.62, boardH: CGFloat = 15
            let board = CGRect(x: W - boardW - 1, y: H - boardH - 1, width: boardW, height: boardH)
            ctx.setFillColor(rgb(0.36, 0.25, 0.15))
            ctx.fill(CGRect(x: board.midX - 1, y: H * 0.36, width: 2, height: board.minY - H * 0.36 + 1))
            let bp = CGPath(roundedRect: board, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.setFillColor(rgb(0.95, 0.9, 0.8))
            ctx.addPath(bp)
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0.36, 0.25, 0.15))
            ctx.setLineWidth(1)
            ctx.addPath(bp)
            ctx.strokePath()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            var fontSize: CGFloat = 8.5
            let font = { NSFont(name: "Chalkboard SE Bold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize) }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(), .foregroundColor: NSColor(calibratedRed: 0.25, green: 0.12, blue: 0.05, alpha: 1),
                .paragraphStyle: para,
            ]
            while (sign as NSString).size(withAttributes: attrs).width > boardW - 4 && fontSize > 5 {
                fontSize -= 0.5
                attrs[.font] = font()
            }
            let ts = (sign as NSString).size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (sign as NSString).draw(in: CGRect(x: board.minX, y: board.midY - ts.height / 2,
                                               width: board.width, height: ts.height), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()

            // tělo ducha: kulatá hlava, zvlněný lem dole
            let gw = W * 0.6, gx = W * 0.08, top = H * 0.74, bottom: CGFloat = 1
            let body = CGMutablePath()
            body.move(to: CGPoint(x: gx, y: bottom + 6))
            body.addLine(to: CGPoint(x: gx, y: top - gw / 2))
            body.addArc(center: CGPoint(x: gx + gw / 2, y: top - gw / 2), radius: gw / 2,
                        startAngle: .pi, endAngle: 0, clockwise: true)
            body.addLine(to: CGPoint(x: gx + gw, y: bottom + 6))
            let waves = 4
            for i in 0..<waves {
                let x0 = gx + gw - CGFloat(i) * gw / CGFloat(waves)
                let x1 = x0 - gw / CGFloat(waves)
                body.addQuadCurve(to: CGPoint(x: x1, y: bottom + 6),
                                  control: CGPoint(x: (x0 + x1) / 2, y: bottom - 2))
            }
            body.closeSubpath()
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            let space = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorSpace: space, colorComponents: [1, 1, 1, 0.97, 0.86, 0.89, 0.95, 0.93],
                                  locations: [0, 1], count: 2)!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
            ctx.restoreGState()
            // ručička držící tyčku
            ctx.setFillColor(rgb(0.97, 0.97, 1, 0.97))
            ctx.fillEllipse(in: CGRect(x: gx + gw - 4, y: H * 0.42, width: 9, height: 7))
            // oči a pusa
            ctx.setFillColor(rgb(0.12, 0.12, 0.16))
            let ey = top - gw * 0.42
            ctx.fillEllipse(in: CGRect(x: gx + gw * 0.28 - 2.2, y: ey - 3, width: 4.4, height: 6))
            ctx.fillEllipse(in: CGRect(x: gx + gw * 0.62 - 2.2, y: ey - 3, width: 4.4, height: 6))
            ctx.fillEllipse(in: CGRect(x: gx + gw * 0.45 - 2.4, y: ey - 11, width: 4.8, height: 5.5))
        }
    }

    static func flower(_ w: Int, _ h: Int) -> [UInt8] {
        canvas(w, h) { ctx, W, H in
            // stopka
            ctx.setStrokeColor(rgb(0.42, 0.3, 0.22))
            ctx.setLineWidth(1.1)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: W / 2, y: H * 0.62))
            ctx.addQuadCurve(to: CGPoint(x: W / 2 + 3, y: 1.5), control: CGPoint(x: W / 2 - 3, y: H * 0.3))
            ctx.strokePath()
            // lístek na stopce
            ctx.setFillColor(rgb(0.45, 0.62, 0.3))
            ctx.saveGState()
            ctx.translateBy(x: W / 2 - 1, y: H * 0.3)
            ctx.rotate(by: 0.6)
            ctx.fillEllipse(in: CGRect(x: 0, y: -1.5, width: 6, height: 3))
            ctx.restoreGState()
            // pět okvětních lístků
            let c = CGPoint(x: W / 2, y: H * 0.66)
            for k in 0..<5 {
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(k) * 2 * .pi / 5 + 0.3)
                let petal = CGMutablePath()
                petal.move(to: .zero)
                petal.addCurve(to: CGPoint(x: 0, y: 7.6), control1: CGPoint(x: 4.6, y: 2.5), control2: CGPoint(x: 3.6, y: 8.4))
                petal.addCurve(to: .zero, control1: CGPoint(x: -3.6, y: 8.4), control2: CGPoint(x: -4.6, y: 2.5))
                ctx.addPath(petal)
                ctx.clip()
                let space = CGColorSpaceCreateDeviceRGB()
                let grad = CGGradient(colorSpace: space,
                                      colorComponents: [0.93, 0.55, 0.68, 1, 1.0, 0.86, 0.9, 1, 1.0, 0.93, 0.95, 1],
                                      locations: [0, 0.55, 1], count: 3)!
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 8), options: [])
                ctx.restoreGState()
            }
            ctx.setFillColor(rgb(0.86, 0.36, 0.5))
            ctx.fillEllipse(in: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6))
            ctx.setFillColor(rgb(1.0, 0.86, 0.45))
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                ctx.fillEllipse(in: CGRect(x: c.x + cos(a) * 2.6 - 0.6, y: c.y + sin(a) * 2.6 - 0.6, width: 1.2, height: 1.2))
            }
        }
    }
}

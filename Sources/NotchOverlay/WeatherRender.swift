import AppKit
import Metal
import QuartzCore

/// GPU prostředky počasí (device, pipelines, atlas). Drží je controller jen
/// po dobu, kdy počasí běží — po vypnutí se uvolní.
final class WeatherGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let spritePipeline: MTLRenderPipelineState
    let stripPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let atlas: MTLTexture
    let uv: [SpriteUV]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            func pipeline(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: v)
                d.fragmentFunction = lib.makeFunction(name: f)
                let att = d.colorAttachments[0]!
                att.pixelFormat = .bgra8Unorm
                att.isBlendingEnabled = true
                // premultiplied alpha; alpha 0 s barvou = aditivní záře
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            spritePipeline = try pipeline("spriteV", "spriteF")
            stripPipeline = try pipeline("stripV", "stripF")
        } catch {
            WeatherLog.write("metal: shader/pipeline failed: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd),
              let built = WeatherAtlas.build(device: device, queue: queue) else { return nil }
        self.sampler = sampler
        atlas = built.texture
        uv = built.uv
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct U { float2 view; float opacity; float time; };

    struct Inst {
        float2 pos; float2 size; float rot; float alpha; float mode; float extra;
        float4 uv; float4 tint;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
        float mode;
        float extra;
        float4 tint;
    };

    vertex VOut spriteV(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Inst* inst [[buffer(0)]], constant U& u [[buffer(1)]]) {
        Inst I = inst[iid];
        float2 c = float2(float(vid & 1), float(vid >> 1));
        float2 p = (c - 0.5) * I.size;
        float s = sin(I.rot), co = cos(I.rot);
        p = float2(p.x * co - p.y * s, p.x * s + p.y * co) + I.pos;
        VOut o;
        o.position = float4(p.x / u.view.x * 2.0 - 1.0, 1.0 - p.y / u.view.y * 2.0, 0.0, 1.0);
        o.uv = mix(I.uv.xy, I.uv.zw, c);
        o.alpha = I.alpha * u.opacity;
        o.mode = I.mode;
        o.extra = I.extra;
        o.tint = I.tint;
        return o;
    }

    fragment float4 spriteF(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
        float4 t = tex.sample(smp, in.uv);
        if (in.mode < 0.5) {
            // materiál: R stín, G vzdálenost od okraje, B odlesk, A tvar
            float a = t.a * in.alpha;
            float3 col = in.tint.rgb * t.r;
            // vadnutí/usychání postupuje od okrajů
            float w = saturate(in.extra * 1.7 - t.g * 1.1);
            col = mix(col, float3(0.46, 0.29, 0.14) * (0.55 + 0.45 * t.r), w);
            col += t.b * in.tint.a;
            return float4(col * a, a);
        } else if (in.mode < 1.5) {
            return t * in.alpha;
        } else {
            float a = t.a * in.alpha;
            return float4(in.tint.rgb * a, 0.0);
        }
    }

    struct SU { float2 view; float opacity; float pad; float4 top; float4 deep; float4 halo; };

    struct SOut {
        float4 position [[position]];
        float depth;
        float halo;
    };

    // Závěj jako pás trojúhelníků: horní vrchol 1,6 bodu nad povrchem (hloubka < 0),
    // dolní na hraně. Povrch (hloubka 0) i stín nad ním dopočítá fragment shader.
    vertex SOut stripV(uint vid [[vertex_id]], const device float4* v [[buffer(0)]],
                       constant SU& u [[buffer(1)]]) {
        float4 p = v[vid];
        SOut o;
        o.position = float4(p.x / u.view.x * 2.0 - 1.0, 1.0 - p.y / u.view.y * 2.0, 0.0, 1.0);
        o.depth = p.z;
        o.halo = p.w;
        return o;
    }

    fragment float4 stripF(SOut in [[stage_in]], constant SU& u [[buffer(1)]]) {
        float d = in.depth;
        float aa = max(fwidth(d), 0.001);
        float body = smoothstep(-aa, aa, d);
        float halo = in.halo * saturate(1.0 + d / 1.6);
        float k = smoothstep(0.5, u.deep.a, d);
        float3 col = mix(u.top.rgb, u.deep.rgb, k);
        float a = body + (1.0 - body) * halo;
        float3 rgb = col * body + u.halo.rgb * (1.0 - body) * halo;
        return float4(rgb * u.opacity, a * u.opacity);
    }
    """
}

/// Barvy závěje pro strip shader (deep.a = hloubka, kde už je plně „deep").
struct PileColors {
    var top: SIMD4<Float>
    var deep: SIMD4<Float>
    var halo: SIMD4<Float>
}

/// Zapisovač instancí spritů (16 floatů na instanci, viz `Inst` v shaderu).
struct SpriteWriter {
    let base: UnsafeMutablePointer<Float>
    let capacity: Int
    var count = 0
    var overflow = false
    let uv: [SpriteUV]

    @inline(__always)
    mutating func add(_ s: Sprite, x: Float, y: Float, w: Float, h: Float, rot: Float = 0,
                      alpha: Float, mode: Float = 0, extra: Float = 0,
                      r: Float = 1, g: Float = 1, b: Float = 1, hi: Float = 0) {
        guard alpha > 0.003 else { return }
        guard count < capacity else { overflow = true; return }
        let t = uv[s.rawValue]
        let p = base + count * 16
        p[0] = x; p[1] = y; p[2] = w; p[3] = h
        p[4] = rot; p[5] = alpha; p[6] = mode; p[7] = extra
        p[8] = t.u0; p[9] = t.v0; p[10] = t.u1; p[11] = t.v1
        p[12] = r; p[13] = g; p[14] = b; p[15] = hi
        count += 1
    }

    /// Barevný sprite oříznutý zdola na `clipY` (vylézá ze závěje): kreslí jen část nad ní.
    @inline(__always)
    mutating func addClipped(_ s: Sprite, cx: Float, bottom: Float, w: Float, h: Float,
                             clipY: Float, alpha: Float) {
        let top = bottom - h
        let visBottom = min(bottom, clipY)
        guard visBottom > top + 0.5, alpha > 0.003 else { return }
        guard count < capacity else { overflow = true; return }
        let frac = (visBottom - top) / h
        let t = uv[s.rawValue]
        let p = base + count * 16
        p[0] = cx; p[1] = top + (visBottom - top) / 2; p[2] = w; p[3] = visBottom - top
        p[4] = 0; p[5] = alpha; p[6] = 1; p[7] = 0
        p[8] = t.u0; p[9] = t.v0; p[10] = t.u1; p[11] = t.v0 + (t.v1 - t.v0) * frac
        p[12] = 1; p[13] = 1; p[14] = 1; p[15] = 0
        count += 1
    }
}

/// Závěje jako pásy trojúhelníků (2 vrcholy na sloupec), každý souvislý úsek zvlášť.
/// Vrchol: float4 (x, y, hloubka od povrchu, síla stínu nad povrchem).
struct StripWriter {
    let base: UnsafeMutablePointer<SIMD4<Float>>
    let capacity: Int
    var count = 0
    var overflow = false
    let ranges: UnsafeMutablePointer<SIMD2<Int32>>
    let rangeCapacity: Int
    var rangeCount = 0
    private var segStart = -1

    init(base: UnsafeMutablePointer<SIMD4<Float>>, capacity: Int,
         ranges: UnsafeMutablePointer<SIMD2<Int32>>, rangeCapacity: Int) {
        self.base = base
        self.capacity = capacity
        self.ranges = ranges
        self.rangeCapacity = rangeCapacity
    }

    static let haloHeight: Float = 1.6

    /// Sloupec závěje: povrch `top`, hrana `base`.
    @inline(__always)
    mutating func column(x: Float, top: Float, base y: Float, halo: Float) {
        guard count + 2 <= capacity else { overflow = true; return }
        if segStart < 0 { segStart = count }
        let hh = Self.haloHeight
        base[count] = SIMD4(x, top - hh, -hh, halo)
        base[count + 1] = SIMD4(x, y, y - top, halo)
        count += 2
    }

    /// Konec souvislého úseku (zakrytý sloupec, konec hrany).
    @inline(__always)
    mutating func end() {
        guard segStart >= 0 else { return }
        if count - segStart >= 4 && rangeCount < rangeCapacity {
            ranges[rangeCount] = SIMD2(Int32(segStart), Int32(count - segStart))
            rangeCount += 1
        } else {
            count = segStart
        }
        segStart = -1
    }
}

/// Vykreslování jedné obrazovky do CAMetalLayer. Bez čekání na GPU a bez
/// completion handlerů (každý by budil další vlákno): buffery se točí ve třech
/// slotech a slot se znovu použije, až jeho command buffer doběhl (při 30 fps vždy).
final class WeatherRenderer {
    private let gpu: WeatherGPU
    private var spriteCap = 4096
    private var stripCap = 8192
    private static let rangeCap = 512
    private var sprites: [MTLBuffer?] = [nil, nil, nil]
    private var strips: [MTLBuffer?] = [nil, nil, nil]
    private var rangeStore: [UnsafeMutablePointer<SIMD2<Int32>>] = []
    private var lastCB: [MTLCommandBuffer?] = [nil, nil, nil]
    private var slot = 0
    private var debugFrames = 0
    static let debug = ProcessInfo.processInfo.environment["WEATHER_DEBUG"] != nil

    init(gpu: WeatherGPU) {
        self.gpu = gpu
        for _ in 0..<3 {
            rangeStore.append(UnsafeMutablePointer<SIMD2<Int32>>.allocate(capacity: Self.rangeCap))
        }
    }

    deinit {
        rangeStore.forEach { $0.deallocate() }
    }

    private func buffer(_ list: inout [MTLBuffer?], _ i: Int, length: Int) -> MTLBuffer? {
        if let b = list[i], b.length >= length { return b }
        list[i] = gpu.device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
        return list[i]
    }

    /// `fill` dostane zapisovače; vrací (počet „zadních" spritů, barvy závějí, průhlednost).
    func draw(layer: CAMetalLayer, viewSize: CGSize,
              fill: (inout SpriteWriter, inout StripWriter) -> (back: Int, colors: PileColors, opacity: Float)) {
        slot = (slot + 1) % 3
        if let prev = lastCB[slot], prev.status != .completed && prev.status != .error {
            prev.waitUntilCompleted()
        }
        guard let sBuf = buffer(&sprites, slot, length: spriteCap * 64),
              let tBuf = buffer(&strips, slot, length: stripCap * 16) else { return }
        var sw = SpriteWriter(base: sBuf.contents().bindMemory(to: Float.self, capacity: spriteCap * 16),
                              capacity: spriteCap, uv: gpu.uv)
        var tw = StripWriter(base: tBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: stripCap),
                             capacity: stripCap, ranges: rangeStore[slot], rangeCapacity: Self.rangeCap)
        let result = fill(&sw, &tw)
        tw.end()
        // buffery rostou podle potřeby (příští snímek už se vejde)
        if sw.overflow { spriteCap = min(spriteCap * 2, 65_536) }
        if tw.overflow { stripCap = min(stripCap * 2, 262_144) }

        guard let drawable = layer.nextDrawable(), let cb = gpu.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

        debugFrames += 1
        if Self.debug && debugFrames % 60 == 1 {
            WeatherLog.write("draw #\(debugFrames): sprites \(sw.count)/\(spriteCap) back \(result.back) strip \(tw.count)/\(stripCap) ranges \(tw.rangeCount) drawable \(layer.drawableSize)")
        }

        var u = SpriteUniforms(view: SIMD2(Float(viewSize.width), Float(viewSize.height)), opacity: result.opacity, time: 0)
        var su = StripUniforms(view: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                               opacity: result.opacity, pad: 0,
                               top: result.colors.top, deep: result.colors.deep, halo: result.colors.halo)

        func drawSprites(from: Int, to: Int) {
            guard to > from else { return }
            enc.setRenderPipelineState(gpu.spritePipeline)
            enc.setVertexBuffer(sBuf, offset: from * 64, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
            enc.setFragmentTexture(gpu.atlas, index: 0)
            enc.setFragmentSamplerState(gpu.sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: to - from)
        }

        drawSprites(from: 0, to: result.back)
        if tw.rangeCount > 0 {
            enc.setRenderPipelineState(gpu.stripPipeline)
            enc.setVertexBuffer(tBuf, offset: 0, index: 0)
            enc.setVertexBytes(&su, length: MemoryLayout<StripUniforms>.stride, index: 1)
            enc.setFragmentBytes(&su, length: MemoryLayout<StripUniforms>.stride, index: 1)
            for r in 0..<tw.rangeCount {
                let range = tw.ranges[r]
                enc.drawPrimitives(type: .triangleStrip, vertexStart: Int(range.x), vertexCount: Int(range.y))
            }
        }
        drawSprites(from: result.back, to: sw.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        lastCB[slot] = cb
    }
}

private struct SpriteUniforms {
    var view: SIMD2<Float>
    var opacity: Float
    var time: Float
}

private struct StripUniforms {
    var view: SIMD2<Float>
    var opacity: Float
    var pad: Float
    var top: SIMD4<Float>
    var deep: SIMD4<Float>
    var halo: SIMD4<Float>
}

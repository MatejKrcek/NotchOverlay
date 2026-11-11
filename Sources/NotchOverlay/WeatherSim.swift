import AppKit

// Simulace počasí pro jednu obrazovku. Souřadnice v bodech, počátek vlevo
// nahoře, y roste dolů (stejně jako CGWindowList).
//
// Závěje jsou výškové mapy po sloupcích (`Ledge`): zem, Dock, horní hrany oken,
// widgety a výběr tažený po ploše. Částice (vločky, listy, kapky…) padají
// přes všechno a usadí se na první viditelné hraně, kterou protnou.

/// Okno v lokálních souřadnicích obrazovky (seřazené odpředu dozadu).
struct LocalWindow {
    let id: Int
    let rect: CGRect
}

struct WeatherConfig {
    var mode: WeatherMode = .snow
    var halloween = false
    var intensity: WeatherIntensity = .steady
    var opacity: Float = 0.9
    var ground = true
    var dock = true
    var windows = true
    var widgets = true
    var melt = true
    var deep = false
    var lowPower = false
}

/// Šířka sloupce výškové mapy v bodech.
private let dx: Float = 3

private enum PK {
    static let flake: UInt8 = 0
    static let leaf: UInt8 = 1
    static let petal: UInt8 = 2
    static let flower: UInt8 = 3
    static let rain: UInt8 = 4
    static let lump: UInt8 = 5
    static let powder: UInt8 = 6
    static let splash: UInt8 = 7
    static let drip: UInt8 = 8
}

private struct Particle {
    var x: Float = 0, y: Float = 0
    /// Impulzní rychlost (vymrštění kurzorem, sesuv z okna) — postupně odezní.
    var ex: Float = 0, ey: Float = 0
    var fall: Float = 0
    var size: Float = 2
    var rot: Float = 0, spin: Float = 0
    var phase: Float = 0, sway: Float = 0, freq: Float = 1
    var flip: Float = 0, flipSpeed: Float = 0
    var depth: Float = 1
    var mass: Float = 0
    var life: Float = -1
    /// Hloubka vůči oknům (1 = úplně vepředu). Dopadne jen na hranu, která sahá
    /// aspoň do téhle hloubky — zadní okna chytají jen vzdálené vločky.
    var z: Float = 1
    /// Hrana, ze které částice právě spadla — chvíli na ni nemůže dopadnout zpátky.
    var src: Int = Int.min
    var srcLife: Float = 0
    var kind: UInt8 = 0
    var sprite: UInt8 = 0
    var tint: UInt8 = 0
}

struct Bead {
    var x: Float, y: Float, r: Float
    var vy: Float = 0
    var stuck: Float = 0
    var hanging = false
    var trail: Float = 0
    var wob: Float = 0
}

struct Speck {
    var x: Float, y: Float, r: Float
    var life: Float, maxLife: Float
}

struct Film {
    var x: Float, y: Float, len: Float, w: Float
    var life: Float, maxLife: Float
}

final class Ledge {
    enum Kind { case ground, dock, window, widget, selection }

    let id: Int
    let kind: Kind
    let radius: Float
    let maxPile: Float
    private(set) var rect: CGRect = .zero
    // Horká pole čtená pro každou částici a sloupec každý snímek: bez dynamických
    // kontrol výlučného přístupu (polovina času simulace). Přístupy se nepřekrývají.
    @exclusivity(unchecked) var x0: Float = 0
    @exclusivity(unchecked) var y: Float = 0
    @exclusivity(unchecked) var n = 0
    @exclusivity(unchecked) var h: [Float] = []
    @exclusivity(unchecked) var age: [Float] = []
    @exclusivity(unchecked) var base: [Float] = []
    @exclusivity(unchecked) var cap: [Float] = []
    /// Obdélníky před touto hranou (zakrývají ji nebo tvoří strop).
    var fronts: [CGRect] = []
    @exclusivity(unchecked) var spill: Float = 0
    @exclusivity(unchecked) var mass: Float = 0
    @exclusivity(unchecked) var carved: Float = 0
    /// Jak hluboko hrana sahá (okna jako krabice opřené o plochu): přední okno 1,
    /// každé další dozadu méně. Zem, Dock, widgety, výběr: 1.
    @exclusivity(unchecked) var z: Float = 1
    @exclusivity(unchecked) var beads: [Bead] = []
    @exclusivity(unchecked) var specks: [Speck] = []
    @exclusivity(unchecked) var films: [Film] = []

    init(id: Int, kind: Kind, rect: CGRect, radius: Float, maxPile: Float) {
        self.id = id
        self.kind = kind
        self.radius = radius
        self.maxPile = maxPile
        _ = layout(rect)
    }

    var hasGlass: Bool { !beads.isEmpty || !specks.isEmpty || !films.isEmpty }

    @inline(__always) func colX(_ i: Int) -> Float { x0 + (Float(i) + 0.5) * dx }
    @inline(__always) func baseY(_ i: Int) -> Float { y + base[i] }

    /// Posun bez změny velikosti: sníh i kapky jedou s oknem.
    func move(to r: CGRect) {
        x0 += Float(r.minX - rect.minX)
        y = Float(r.minY)
        rect = r
    }

    /// Nové rozměry; sloupce se přemapují podle globálního x. Vrací sníh,
    /// který se na nové hraně nemá kde udržet (x, y povrchu, množství v bodech²).
    func layout(_ r: CGRect) -> [(Float, Float, Float)] {
        let oldX0 = x0, oldN = n, oldH = h, oldAge = age, oldBase = base, oldY = y
        rect = r
        x0 = Float(r.minX)
        y = Float(r.minY)
        n = max(1, min(2000, Int((Float(r.width) / dx).rounded(.up))))
        h = [Float](repeating: 0, count: n)
        age = [Float](repeating: 0, count: n)
        base = [Float](repeating: 0, count: n)
        cap = [Float](repeating: 0, count: n)
        let width = Float(r.width)
        for i in 0..<n {
            // zaoblené rohy: hrana u kraje klesá po kružnici
            let d = min(Float(i) + 0.5, Float(n) - Float(i) - 0.5) * dx
            let dEdge = min(d, width - d)
            if radius > 0 && dEdge < radius {
                let q = radius - dEdge
                base[i] = radius - (radius * radius - q * q).squareRoot()
            }
        }
        var lost: [(Float, Float, Float)] = []
        guard oldN > 0, !oldH.isEmpty else { return lost }
        var used = [Bool](repeating: false, count: oldN)
        for i in 0..<n {
            let gx = x0 + (Float(i) + 0.5) * dx
            let j = Int(((gx - oldX0) / dx).rounded(.down))
            if j >= 0 && j < oldN {
                h[i] = oldH[j]
                age[i] = oldAge[j]
                used[j] = true
            }
        }
        for j in 0..<oldN where !used[j] && oldH[j] > 0.2 {
            let gx = oldX0 + (Float(j) + 0.5) * dx
            lost.append((gx, oldY + oldBase[j] - oldH[j], oldH[j] * dx))
        }
        return lost
    }
}

private struct Ghost {
    let ledgeId: Int
    let col: Int
    let start: Double
    let sprite: Sprite
    var popped = false
}

private struct RNG {
    var s: UInt64
    @inline(__always) mutating func next() -> UInt64 {
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        return s
    }
    @inline(__always) mutating func f() -> Float { Float(next() >> 40) / 16_777_216 }
    @inline(__always) mutating func r(_ a: Float, _ b: Float) -> Float { a + (b - a) * f() }
    @inline(__always) mutating func i(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

@inline(__always) private func hash01(_ a: Int, _ b: Int) -> Float {
    var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
    x ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
    x ^= x >> 29
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 32
    return Float(x >> 40) / 16_777_216
}

@inline(__always) private func cbrtf(_ x: Float) -> Float { Float(cbrt(Double(max(0, x)))) }

@inline(__always) private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

private let leafTints: [(Float, Float, Float)] = [
    (0.86, 0.37, 0.12), (0.76, 0.2, 0.1), (0.94, 0.62, 0.17), (0.9, 0.76, 0.26),
    (0.56, 0.31, 0.13), (0.68, 0.16, 0.12), (0.82, 0.5, 0.15), (0.62, 0.46, 0.19),
]
private let petalTints: [(Float, Float, Float)] = [
    (1.0, 0.82, 0.87), (0.98, 0.73, 0.81), (1.0, 0.9, 0.93), (0.96, 0.67, 0.77), (0.99, 0.78, 0.84),
]
private let leafSprites: [Sprite] = [.leafMaple, .leafOval, .leafOak, .leafBirch]

final class WeatherSim {
    let W: Float
    let H: Float
    var config = WeatherConfig()

    private var ground: Ledge
    private var dockLedge: Ledge?
    private var windowLedges: [Int: Ledge] = [:]
    private var widgetLedges: [Int: Ledge] = [:]
    private var selection: Ledge?
    private var pending: [(Ledge, Double)] = []
    private var stash: [Int: (Ledge, Double)] = [:]
    private var spaceChangedAt: Double = -100
    private var windowRects: [CGRect] = []
    private var dockRect: CGRect?
    private var topLimit: Float = 0

    /// Aktivní hrany (pro dopady a kreslení) + mapa sloupců obrazovky → hrany.
    @exclusivity(unchecked) private var ledges: [Ledge] = []
    private static let K = 12
    @exclusivity(unchecked) private var cols = 0
    @exclusivity(unchecked) private var colMap: [Int32] = []
    @exclusivity(unchecked) private var colCount: [UInt8] = []
    private var mapDirty = true

    @exclusivity(unchecked) private var parts = ContiguousArray<Particle>()
    @exclusivity(unchecked) private var rng = RNG(s: UInt64(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)) | 1)
    @exclusivity(unchecked) private var t: Double = 0
    @exclusivity(unchecked) private var frame = 0
    private var spawnAcc: Float = 0
    private var clearing: Float = 0

    private var mousePrev: SIMD2<Float>?
    private var mouseVel = SIMD2<Float>(0, 0)
    private var wasDown = false
    private var selectStart: SIMD2<Float>?

    private var ghost: Ghost?
    private var nextGhost: Double = 6
    /// Počet rychlých částic (hroudy, sprej, kapky, šplíchance) v posledním kroku —
    /// dokud nějaké letí, overlay kreslí plynuleji.
    private(set) var fastParticles = 0

    init(width: Float, height: Float) {
        W = width
        H = height
        ground = Ledge(id: -1, kind: .ground, rect: CGRect(x: 0, y: CGFloat(height), width: CGFloat(width), height: 0),
                       radius: 0, maxPile: 60)
    }

    // MARK: - Scéna (okna, Dock)

    func noteSpaceChange(now: Double) {
        spaceChangedAt = now
    }

    func setScene(windows: [LocalWindow], widgets: [LocalWindow], dock: CGRect?, topLimit: Float,
                  now: Double, pollDt: Double, closed: Set<Int> = []) {
        self.topLimit = topLimit
        windowRects = windows.map(\.rect)

        // Dock
        let wantDock = config.dock && dock != nil
        if wantDock, let d = dock {
            if let dl = dockLedge {
                if dl.rect != d { update(dl, to: d, dt: pollDt) }
            } else {
                dockLedge = Ledge(id: -2, kind: .dock, rect: d, radius: 18, maxPile: 22)
            }
        } else if let dl = dockLedge {
            dropAll(dl)
            dockLedge = nil
        }
        dockRect = dock

        // Okna
        var seen = Set<Int>()
        if config.windows {
            for w in windows {
                seen.insert(w.id)
                if let L = windowLedges[w.id] {
                    update(L, to: w.rect, dt: pollDt)
                } else if let idx = pending.firstIndex(where: { $0.0.id == w.id }) {
                    let L = pending.remove(at: idx).0
                    windowLedges[w.id] = L
                    update(L, to: w.rect, dt: pollDt)
                } else if let (L, _) = stash.removeValue(forKey: w.id) {
                    // návrat z jiného Space: sníh jede s oknem
                    windowLedges[w.id] = L
                    if L.rect.size == w.rect.size { L.move(to: w.rect) } else { _ = L.layout(w.rect) }
                } else {
                    windowLedges[w.id] = Ledge(id: w.id, kind: .window, rect: w.rect, radius: 12, maxPile: 26)
                }
            }
        }
        for (id, L) in windowLedges where !seen.contains(id) {
            windowLedges.removeValue(forKey: id)
            // zavřené okno: hned; minimalizované / jiný Space: krátce počkat na notifikaci Space
            if config.windows && !closed.contains(id) { pending.append((L, now)) } else { dropAll(L) }
        }

        // Widgety na ploše
        var seenW = Set<Int>()
        if config.widgets {
            for w in widgets {
                seenW.insert(w.id)
                if let L = widgetLedges[w.id] {
                    update(L, to: w.rect, dt: pollDt)
                } else {
                    widgetLedges[w.id] = Ledge(id: w.id, kind: .widget, rect: w.rect, radius: 18, maxPile: 20)
                }
            }
        }
        for (id, L) in widgetLedges where !seenW.contains(id) {
            widgetLedges.removeValue(forKey: id)
            dropAll(L)
        }

        // Zmizelá okna: zavřené/minimalizované → sníh spadne; jiný Space → počká.
        pending.removeAll { entry in
            let (L, since) = entry
            guard now - since >= 0.3 else { return false }
            if spaceChangedAt > since - 1.0 {
                stash[L.id] = (L, now)
            } else {
                dropAll(L)
            }
            return true
        }
        stash = stash.filter { now - $0.value.1 < 1800 }

        computeOcclusion(windows: windows)
        mapDirty = true
    }

    /// Pohyb / změna velikosti okna: sníh sklouzne, kapky odletí.
    private func update(_ L: Ledge, to r: CGRect, dt: Double) {
        let old = L.rect
        guard old != r else { return }
        let ddx = Float(r.minX - old.minX), ddy = Float(r.minY - old.minY)
        if abs(r.width - old.width) > 0.5 || abs(r.height - old.height) > 0.5 {
            for (x, y, m) in L.layout(r) { shedChunk(x: x, y: y, mass: m, vx: 0, vy: 0, z: L.z, from: L.id) }
        } else {
            L.move(to: r)
        }
        let dist = (ddx * ddx + ddy * ddy).squareRoot()
        guard dist > 1 else { return }
        let pdt = Float(max(0.02, min(0.3, dt)))
        let vx = ddx / pdt, vy = ddy / pdt
        let speed = dist / pdt
        shed(L, fraction: min(0.85, 0.15 + speed / 1600), vx: vx, vy: vy)
        if speed > 240 { throwGlass(L, vx: vx, vy: vy) }
    }

    private func computeOcclusion(windows: [LocalWindow]) {
        var all = windowRects
        if let d = dockRect { all.append(d) }
        func relevant(_ list: [CGRect], for L: Ledge) -> [CGRect] {
            let r = L.rect
            let bottom = r.minY + CGFloat(L.radius) + 1
            return list.filter { $0.maxX >= r.minX && $0.minX <= r.maxX && $0.minY < max(bottom, r.maxY) }
        }
        ground.fronts = dockRect.map { [$0] } ?? []
        applyCaps(ground)
        if let dl = dockLedge {
            dl.fronts = []
            applyCaps(dl)
        }
        for (k, w) in windows.enumerated() {
            guard let L = windowLedges[w.id] else { continue }
            L.z = max(0.3, 1 - 0.25 * Float(k))
            var f = Array(windowRects[0..<k])
            if let d = dockRect { f.append(d) }
            L.fronts = relevant(f, for: L)
            applyCaps(L)
        }
        for L in widgetLedges.values {
            L.fronts = relevant(all, for: L)
            applyCaps(L)
        }
        if let s = selection {
            s.fronts = relevant(all, for: s)
            applyCaps(s)
        }
    }

    /// Strop a viditelnost každého sloupce podle oken před hranou.
    /// cap < 0: na sloupec nic nedopadne a nekreslí se — buď je zakrytý oknem
    /// vepředu (sníh pod ním zůstává schovaný), nebo nad ním není místo
    /// (maximalizované okno pod menu barem): vločky padají dál přes okno.
    private func applyCaps(_ L: Ledge) {
        // o místě nad hranou rozhoduje rovná horní hrana, ne kapsy v zaoblených rozích
        let roomAbove = L.kind == .ground ? Float.greatestFiniteMagnitude : L.y - topLimit
        for i in 0..<L.n {
            let x = L.colX(i)
            let by = L.baseY(i)
            var c = roomAbove < 2 ? 0 : min(L.maxPile, by - topLimit)
            var covered = false
            if x < 0 || x > W {
                covered = true
            } else {
                for f in L.fronts where Float(f.minX) <= x && x <= Float(f.maxX) {
                    let fy0 = Float(f.minY), fy1 = Float(f.maxY)
                    if fy0 < by - 0.5 && fy1 > by - 0.5 {
                        covered = true
                        break
                    } else if fy1 <= by - 0.5 {
                        c = min(c, by - fy1)
                    }
                }
            }
            if covered {
                c = -1
            } else if c < 2 {
                // bez místa nad hranou: co tu leželo, sesype se
                if L.h[i] > 0.2 {
                    spawnLoose(x: x, y: by - L.h[i], mass: L.h[i] * dx, vx: rng.r(-15, 15), vy: 0, z: L.z)
                    L.mass = max(0, L.mass - L.h[i])
                }
                L.h[i] = 0
                c = -1
            }
            L.cap[i] = c
        }
    }

    private func rebuildMap() {
        mapDirty = false
        var list: [Ledge] = []
        if config.ground || config.mode == .rain { list.append(ground) }
        if let d = dockLedge { list.append(d) }
        list.append(contentsOf: windowLedges.values)
        list.append(contentsOf: widgetLedges.values)
        if let s = selection { list.append(s) }
        ledges = list
        cols = Int(W / dx) + 2
        let K = Self.K
        if colCount.count != cols {
            colCount = [UInt8](repeating: 0, count: cols)
            colMap = [Int32](repeating: -1, count: cols * K)
        } else {
            for i in 0..<cols { colCount[i] = 0 }
        }
        for (li, L) in list.enumerated() {
            let c0 = max(0, Int((L.x0 / dx).rounded(.down)))
            let c1 = min(cols - 1, Int(((L.x0 + Float(L.n) * dx) / dx).rounded(.down)))
            guard c0 <= c1 else { continue }
            for c in c0...c1 {
                let k = Int(colCount[c])
                if k < K {
                    colMap[c * K + k] = Int32(li)
                    colCount[c] = UInt8(k + 1)
                }
            }
        }
    }

    // MARK: - Ovládání

    /// Je kurzor u nějaké závěje (může do ní hrábnout)?
    func cursorNearPile(_ m: SIMD2<Float>) -> Bool {
        for L in ledges where L.mass > 0.3 {
            guard m.x >= L.x0 - 20, m.x <= L.x0 + Float(L.n) * dx + 20 else { continue }
            if m.y > L.y - L.maxPile - 30 && m.y < L.y + L.radius + 12 { return true }
        }
        return false
    }

    /// Něco se hýbe rychle (duch, mazání, rozmazávání kapek) — kreslit plynule.
    var animating: Bool { fastParticles > 0 || ghost != nil || clearing > 0 || config.mode == .rain }

    func clearAll() {
        clearing = 0.6
    }

    /// Nový mód: závěje zmizí, staré částice taky (sníh nemá dopadat do hromádky listí).
    func modeChanged() {
        clearAll()
        ghost = nil
        parts.removeAll(keepingCapacity: true)
        prewarm()
        mapDirty = true
    }

    func accumulationChanged() {
        if !config.windows {
            for L in windowLedges.values { dropAll(L) }
            windowLedges.removeAll()
            pending.removeAll()
            stash.removeAll()
        }
        if !config.widgets {
            for L in widgetLedges.values { dropAll(L) }
            widgetLedges.removeAll()
        }
        if !config.dock, let d = dockLedge {
            dropAll(d)
            dockLedge = nil
        }
        if !config.ground {
            for i in 0..<ground.n { ground.h[i] = 0 }
            ground.mass = 0
        }
        mapDirty = true
    }

    /// Hned po zapnutí: obrazovka už je plná padajících vloček.
    func prewarm() {
        let fallTime: Float
        switch config.mode {
        case .snow: fallTime = H / 42
        case .leaves: fallTime = H / 48
        case .blossom: fallTime = H / 34
        case .rain: fallTime = H / 800
        }
        let count = Int(spawnRate() * fallTime)
        for _ in 0..<min(count, maxParticles()) {
            spawnOne(y: rng.r(-20, H - 40))
        }
    }

    // MARK: - Krok simulace

    func step(dt rawDt: Float, mouse: SIMD2<Float>?, mouseDown: Bool) {
        let dt = max(0.001, min(rawDt, 1 / 20))
        t += Double(dt)
        frame += 1

        if clearing > 0 {
            clearing -= dt
            let k = exp(-9 * dt)
            for L in allLedges() {
                for i in 0..<L.n { L.h[i] = clearing > 0 ? L.h[i] * k : 0 }
                if clearing <= 0 {
                    L.mass = 0
                    L.beads.removeAll()
                    L.specks.removeAll()
                    L.films.removeAll()
                }
            }
        }

        handleSelection(mouse: mouse, down: mouseDown)
        if mapDirty { rebuildMap() }

        spawn(dt)
        if let m = mouse {
            if let p = mousePrev {
                let v = (m - p) / dt
                mouseVel = mouseVel * 0.5 + v * 0.5
            }
            mousePrev = m
            interact(m, dt: dt)
        } else {
            mousePrev = nil
            mouseVel = .zero
        }
        integrate(dt)

        if config.mode != .rain {
            for L in ledges { settle(L, dt: dt) }
        } else {
            for L in ledges where L.kind != .ground && L.hasGlass { updateGlass(L, dt: dt) }
        }
        if config.halloween && config.mode == .snow { updateGhost() } else { ghost = nil }
    }

    private func allLedges() -> [Ledge] {
        var list = [ground]
        if let d = dockLedge { list.append(d) }
        list.append(contentsOf: windowLedges.values)
        list.append(contentsOf: widgetLedges.values)
        if let s = selection { list.append(s) }
        return list
    }

    // MARK: Spawn

    private func intensityLevel() -> Float {
        switch config.intensity {
        case .light: return 0.42
        case .steady: return 1
        case .heavy: return 2.3
        case .variable:
            // pomalé střídání od poprašku po chumelenici (perioda několik minut)
            let s = 0.5 + 0.5 * sin(t / 97 + 0.8 * sin(t / 41))
            return Float(0.15 + 2.3 * pow(s, 1.6))
        }
    }

    private func spawnRate() -> Float {
        let perK: Float
        switch config.mode {
        case .snow: perK = 40
        case .leaves: perK = 3.4
        case .blossom: perK = 7
        case .rain: perK = 230
        }
        // spawn se rozkládá na šířku + rezervu po větru (≈ 1,4×)
        return perK * intensityLevel() * (W / 1000) * 1.4
    }

    private func maxParticles() -> Int {
        switch config.mode {
        case .snow: return config.lowPower ? 2600 : 3200
        case .leaves: return 600
        case .blossom: return 800
        case .rain: return config.lowPower ? 1400 : 2400
        }
    }

    private func spawn(_ dt: Float) {
        spawnAcc += spawnRate() * dt
        let cap = maxParticles()
        while spawnAcc >= 1 {
            spawnAcc -= 1
            if parts.count < cap { spawnOne(y: -rng.r(4, 30)) }
        }
    }

    private func spawnOne(y: Float) {
        var p = Particle()
        p.x = rng.r(-0.2 * W, 1.2 * W)
        p.y = y
        p.phase = rng.r(0, 6.283)
        p.rot = rng.r(0, 6.283)
        switch config.mode {
        case .snow:
            let d = rng.r(0.22, 1)
            p.kind = PK.flake
            p.depth = d
            p.z = d
            p.size = 1.2 + 3.3 * d * d + (rng.f() < 0.05 ? rng.r(1, 2.4) : 0)
            p.fall = 16 + 44 * d + rng.r(-4, 4)
            p.sway = rng.r(4, 13)
            p.freq = rng.r(0.35, 1.05)
            p.spin = rng.r(-0.6, 0.6)
            let roll = rng.f()
            p.sprite = UInt8(p.size > 4.4 && roll < 0.35 ? Sprite.flakeCrystal.rawValue
                             : roll < 0.6 ? Sprite.flakeSoft.rawValue : Sprite.flakeFluffy.rawValue)
            p.mass = 0.3 * p.size * p.size
        case .leaves:
            p.kind = PK.leaf
            p.depth = rng.r(0.6, 1)
            p.z = rng.r(0.22, 1)
            p.size = rng.r(11, 17)
            p.fall = rng.r(36, 58)
            p.sway = rng.r(24, 44)
            p.freq = rng.r(1.0, 1.8)
            p.flipSpeed = rng.r(1.4, 3.8) * (rng.f() < 0.5 ? -1 : 1)
            p.spin = rng.r(-0.6, 0.6)
            p.sprite = UInt8(leafSprites[rng.i(leafSprites.count)].rawValue)
            p.tint = UInt8(rng.i(leafTints.count))
            p.mass = 15
        case .blossom:
            if rng.f() < 0.025 {
                p.kind = PK.flower
                p.z = rng.r(0.22, 1)
                p.size = 1
                p.fall = rng.r(46, 62)
                p.sway = rng.r(8, 16)
                p.freq = rng.r(0.6, 1.2)
                p.spin = rng.r(2.4, 4.6) * (rng.f() < 0.5 ? -1 : 1)
                p.mass = 14
            } else {
                p.kind = PK.petal
                p.depth = rng.r(0.5, 1)
                p.z = rng.r(0.22, 1)
                p.size = rng.r(5.5, 9)
                p.fall = rng.r(24, 40)
                p.sway = rng.r(16, 30)
                p.freq = rng.r(1.2, 2.2)
                p.flipSpeed = rng.r(2.6, 6) * (rng.f() < 0.5 ? -1 : 1)
                p.spin = rng.r(-1, 1)
                p.sprite = UInt8(rng.f() < 0.5 ? Sprite.petal.rawValue : Sprite.petalCurled.rawValue)
                p.tint = UInt8(rng.i(petalTints.count))
                p.mass = 5
            }
        case .rain:
            let d = rng.r(0.3, 1)
            p.kind = PK.rain
            p.depth = d
            p.z = d
            p.fall = 620 + 360 * d
            p.size = d
        }
        parts.append(p)
    }

    // MARK: Pohyb částic

    @inline(__always) private func wind() -> Float {
        Float(7 * sin(t / 23) + 4 * sin(t / 9.7 + 1.3) + 2.5 * sin(t / 4.3 + 0.4))
    }

    private func integrate(_ dt: Float) {
        var fast = 0
        defer { fastParticles = fast }
        let w = wind()
        let tf = Float(t.truncatingRemainder(dividingBy: 10_000))
        let decayFast = exp(-2.2 * dt), decaySlow = exp(-1.4 * dt), decayLump = exp(-0.4 * dt)
        var i = 0
        while i < parts.count {
            var p = parts[i]
            let yPrev = p.y
            var alive = true
            if p.srcLife > 0 { p.srcLife -= dt }
            var vy: Float = 0
            switch p.kind {
            case PK.flake, PK.powder:
                if p.ey < 0 { p.ey += 260 * dt } else { p.ey *= decayFast }
                p.ex *= decayFast
                let sway = p.sway * sin(tf * p.freq + p.phase)
                let vx = w * (0.35 + 0.65 * p.depth) + sway + p.ex
                vy = p.fall + p.ey
                p.x += vx * dt
                p.y += vy * dt
                p.rot += p.spin * dt
                if p.kind == PK.powder {
                    p.life -= dt
                    if p.life <= 0 { alive = false }
                }
            case PK.leaf, PK.petal:
                if p.ey < 0 { p.ey += 220 * dt } else { p.ey *= decaySlow }
                p.ex *= decaySlow
                let agitation = abs(p.ex) + abs(p.ey)
                let calm = 1 / (1 + agitation * 0.03)
                let swing = sin(tf * p.freq + p.phase)
                let vx = w * 1.2 + p.sway * swing * calm + p.ex
                vy = p.fall * (0.45 + 0.55 * swing * swing) * calm + p.ey
                p.x += vx * dt
                p.y += vy * dt
                p.rot = p.spin + swing * 0.9 * calm + (1 - calm) * p.rot
                p.flip += p.flipSpeed * dt * (1 + (1 - calm) * 2)
            case PK.flower:
                if p.ey < 0 { p.ey += 220 * dt } else { p.ey *= decaySlow }
                p.ex *= decaySlow
                let vx = w * 0.8 + p.sway * sin(tf * p.freq + p.phase) + p.ex
                vy = p.fall + p.ey
                p.x += vx * dt
                p.y += vy * dt
                p.rot += p.spin * dt
            case PK.rain:
                vy = p.fall
                p.x += (w * 1.8 + p.ex) * dt
                p.y += vy * dt
            case PK.lump, PK.drip:
                p.ey = min(p.ey + 950 * dt, 950)
                p.ex *= decayLump
                vy = p.ey
                p.x += p.ex * dt
                p.y += vy * dt
                p.rot += p.spin * dt
            default: // splash
                p.ey += 1100 * dt
                vy = p.ey
                p.x += p.ex * dt
                p.y += vy * dt
                p.life -= dt
                if p.life <= 0 { alive = false }
            }

            if alive && vy > 0 && p.kind != PK.splash {
                if let (li, col, surf) = findLanding(x: p.x, y0: yPrev, y1: p.y, z: p.z, skip: p.srcLife > 0 ? p.src : Int.min) {
                    land(p, ledge: ledges[li], col: col, surf: surf)
                    alive = false
                }
            }
            if alive && (p.y > H + 40 || p.x < -0.35 * W - 60 || p.x > 1.35 * W + 60) { alive = false }

            if alive {
                if p.kind == PK.lump || p.kind == PK.splash || p.kind == PK.drip || abs(p.ex) + abs(p.ey) > 60 {
                    fast += 1
                }
                parts[i] = p
                i += 1
            } else {
                let last = parts.count - 1
                if i != last { parts[i] = parts[last] }
                parts.removeLast()
            }
        }
    }

    /// První viditelná hrana, jejíž povrch částice v tomto kroku protnula.
    @inline(__always)
    private func findLanding(x: Float, y0: Float, y1: Float, z: Float, skip: Int) -> (Int, Int, Float)? {
        guard x >= 0 else { return nil }
        let c = Int(x / dx)
        guard c < cols else { return nil }
        let K = Self.K
        var best: (Int, Int, Float)?
        for k in 0..<Int(colCount[c]) {
            let li = Int(colMap[c * K + k])
            let L = ledges[li]
            guard z <= L.z + 0.001, L.id != skip else { continue }
            let i = Int(((x - L.x0) / dx).rounded(.down))
            guard i >= 0 && i < L.n, L.cap[i] >= 0 else { continue }
            let by = L.y + L.base[i]
            let surf = by - L.h[i]
            if y0 <= by + 0.5 && y1 >= surf {
                if best == nil || surf < best!.2 { best = (li, i, surf) }
            }
        }
        return best
    }

    private func land(_ p: Particle, ledge L: Ledge, col i: Int, surf: Float) {
        switch p.kind {
        case PK.flake, PK.powder:
            deposit(L, i, p.mass)
        case PK.leaf, PK.petal, PK.flower:
            deposit(L, i, p.mass)
        case PK.lump:
            deposit(L, i, p.mass * 0.45)
            let n = min(14, Int(p.mass / 1.6) + 3)
            let each = p.mass * 0.55 / Float(n)
            for _ in 0..<n {
                var q = Particle()
                q.kind = PK.powder
                q.z = p.z
                q.x = p.x + rng.r(-2, 2)
                q.y = surf - 1
                q.ex = rng.r(-110, 110)
                q.ey = -rng.r(50, 160)
                q.fall = rng.r(30, 55)
                q.size = rng.r(1.2, 2.4)
                q.depth = 1
                q.mass = each
                q.life = rng.r(1.6, 2.8)
                q.sway = rng.r(2, 6)
                q.freq = rng.r(0.5, 1)
                q.sprite = UInt8(Sprite.flakeSoft.rawValue)
                parts.append(q)
            }
        case PK.rain, PK.drip:
            splash(x: p.x, y: surf, strength: p.kind == PK.drip ? 1.6 : p.depth)
            if L.kind != .ground && L.kind != .selection { rainOnGlass(L, x: p.x) }
        default:
            break
        }
    }

    private func splash(x: Float, y: Float, strength: Float) {
        guard parts.count < maxParticles() + 900 else { return }
        let n = 1 + rng.i(strength > 0.7 ? 4 : 2)
        for _ in 0..<n {
            var q = Particle()
            q.kind = PK.splash
            q.x = x
            q.y = y - 0.5
            q.ex = rng.r(-70, 70) * strength
            q.ey = -rng.r(60, 170) * strength
            q.size = rng.r(0.9, 1.7)
            q.life = rng.r(0.22, 0.4)
            q.depth = strength
            parts.append(q)
        }
    }

    // MARK: Závěje

    private func deposit(_ L: Ledge, _ i: Int, _ m: Float) {
        let add = m / dx
        let j = rng.f()
        let wl = 0.15 + 0.2 * j
        let wr = 0.35 - 0.2 * j
        addHeight(L, i - 1, add * wl)
        addHeight(L, i, add * (1 - wl - wr))
        addHeight(L, i + 1, add * wr)
    }

    @inline(__always) private func addHeight(_ L: Ledge, _ i: Int, _ a: Float) {
        guard i >= 0 && i < L.n, L.cap[i] >= 0 else { return }
        let room = L.cap[i] - L.h[i]
        guard room > 0 else { return }
        let v = min(a, room)
        let old = L.h[i]
        L.h[i] = old + v
        // čerstvé listy/lístky omlazují sloupec
        if L.age[i] > 0 { L.age[i] *= old / (old + v) }
        L.mass += v
    }

    /// Sesouvání na sypný úhel, přetékání přes hrany, tání.
    private func settle(_ L: Ledge, dt: Float) {
        guard L.mass > 0.01 || L.carved > 0 else { return }
        let n = L.n
        let snow = config.mode == .snow
        let slope: Float = snow ? 0.62 : 0.85
        let lim = slope * dx
        let fwd = (frame & 1) == 0
        L.h.withUnsafeMutableBufferPointer { hp in
            L.base.withUnsafeBufferPointer { bp in
                L.cap.withUnsafeBufferPointer { cp in
                    guard n > 1 else { return }
                    for pass in 0..<2 {
                        let forward = fwd != (pass == 1)
                        for k in 0..<(n - 1) {
                            let a = forward ? k : n - 2 - k
                            let b = a + 1
                            guard cp[a] >= 0, cp[b] >= 0 else { continue }
                            let diff = (bp[b] - hp[b]) - (bp[a] - hp[a])  // > 0: a je výš
                            if diff > lim {
                                var tr = (diff - lim) * 0.4
                                tr = min(tr, hp[a], max(0, cp[b] - hp[b]))
                                hp[a] -= tr
                                hp[b] += tr
                            } else if diff < -lim {
                                var tr = (-diff - lim) * 0.4
                                tr = min(tr, hp[b], max(0, cp[a] - hp[a]))
                                hp[b] -= tr
                                hp[a] += tr
                            }
                        }
                    }
                }
            }
        }

        // přetékání přes krajní sloupce (okna, Dock, výběr) a přes strop
        if L.kind != .ground {
            for e in [0, n - 1] where L.cap[e] >= 0 && L.h[e] > 0.8 {
                let ex = (L.h[e] - 0.8) * min(1, dt * 4)
                L.h[e] -= ex
                L.spill += ex * dx
                let unit: Float = snow ? 2.2 : (config.mode == .leaves ? 15 : 5)
                if L.spill >= unit {
                    L.spill -= unit
                    let out: Float = e == 0 ? -1 : 1
                    let x = L.colX(e) + out * dx
                    spawnLoose(x: x, y: L.baseY(e) - L.h[e], mass: unit, vx: out * rng.r(8, 30), vy: -rng.r(0, 15), z: L.z, from: L.id)
                }
            }
        }

        var mass: Float = 0
        let melt = config.melt
        let leaves = !snow
        for i in 0..<n {
            var h = L.h[i]
            let c = L.cap[i]
            if c >= 0 && h > c + 0.05 {
                // strop se snížil (okno nad hranou): přebytek spadne
                let ex = h - c
                h = c
                if ex * dx > 1.5 { spawnLoose(x: L.colX(i), y: L.baseY(i) - h, mass: ex * dx, vx: rng.r(-20, 20), vy: 0, z: L.z) }
            }
            if melt && h > 0 {
                if leaves {
                    L.age[i] = min(1.5, L.age[i] + dt / 100)
                    let a = L.age[i]
                    h -= (0.003 + h * (a > 0.7 ? (a - 0.7) / 60 : 0)) * dt
                } else {
                    h -= (0.004 + h / 150) * dt
                }
                if h < 0 { h = 0 }
            }
            L.h[i] = h
            mass += h
        }
        L.mass = mass
        L.carved = 0
    }

    /// Volný kus závěje (přetečení, sesuv): sníh jako prášek, listy jako listy.
    private func spawnLoose(x: Float, y: Float, mass: Float, vx: Float, vy: Float, z: Float = 1,
                            from src: Int = Int.min) {
        guard parts.count < maxParticles() + 1200 else { return }
        var q = Particle()
        q.z = z
        q.src = src
        q.srcLife = src == Int.min ? 0 : 0.35
        q.x = x
        q.y = y
        q.ex = vx
        q.ey = vy
        q.phase = rng.r(0, 6.283)
        q.rot = rng.r(0, 6.283)
        switch config.mode {
        case .snow, .rain:
            q.kind = PK.powder
            q.size = min(3.2, 1.2 + mass * 0.25)
            q.fall = rng.r(34, 56)
            q.depth = 1
            q.mass = mass
            q.life = 6
            q.sway = rng.r(2, 6)
            q.freq = rng.r(0.5, 1)
            q.sprite = UInt8(Sprite.flakeSoft.rawValue)
        case .leaves:
            q.kind = PK.leaf
            q.size = rng.r(11, 16)
            q.fall = rng.r(36, 56)
            q.sway = rng.r(22, 40)
            q.freq = rng.r(1, 1.8)
            q.flipSpeed = rng.r(1.4, 3.8)
            q.spin = rng.r(-0.6, 0.6)
            q.sprite = UInt8(leafSprites[rng.i(leafSprites.count)].rawValue)
            q.tint = UInt8(rng.i(leafTints.count))
            q.depth = 1
            q.mass = mass
        case .blossom:
            q.kind = PK.petal
            q.size = rng.r(5.5, 9)
            q.fall = rng.r(24, 40)
            q.sway = rng.r(16, 30)
            q.freq = rng.r(1.2, 2.2)
            q.flipSpeed = rng.r(2.6, 6)
            q.spin = rng.r(-1, 1)
            q.sprite = UInt8(rng.f() < 0.5 ? Sprite.petal.rawValue : Sprite.petalCurled.rawValue)
            q.tint = UInt8(rng.i(petalTints.count))
            q.depth = 1
            q.mass = mass
        }
        parts.append(q)
    }

    /// Kus sesutý z pohnutého okna: sníh v hroudách, listy jednotlivě.
    private func shedChunk(x: Float, y: Float, mass: Float, vx: Float, vy: Float, z: Float = 1,
                           from src: Int = Int.min) {
        guard mass > 0.3, parts.count < maxParticles() + 1500 else { return }
        let ivx = max(-260, min(260, vx * 0.35))
        let ivy = max(-120, min(200, vy * 0.35))
        if config.mode == .snow && mass >= 3 {
            var q = Particle()
            q.z = z
            q.src = src
            q.srcLife = src == Int.min ? 0 : 0.35
            q.kind = PK.lump
            q.x = x
            q.y = y
            q.ex = ivx + rng.r(-20, 20)
            q.ey = min(ivy, 40) - rng.r(0, 25)
            q.size = min(10, 1.7 * mass.squareRoot())
            q.mass = mass
            q.spin = rng.r(-3, 3)
            q.sprite = UInt8(Sprite.flakeFluffy.rawValue)
            parts.append(q)
        } else {
            spawnLoose(x: x, y: y, mass: mass, vx: ivx + rng.r(-25, 25),
                       vy: min(ivy, 0) - rng.r(5, 30), z: z, from: src)
        }
    }

    private func shed(_ L: Ledge, fraction: Float, vx: Float, vy: Float) {
        guard L.mass > 0.05 else { return }
        let unit: Float = config.mode == .snow ? 7 : (config.mode == .leaves ? 15 : 5)
        var acc: Float = 0
        var spawned = 0
        for i in 0..<L.n where L.h[i] > 0.1 && L.cap[i] >= 0 {
            let take = L.h[i] * fraction
            L.h[i] -= take
            L.mass -= take
            acc += take * dx
            if acc >= unit || (i == L.n - 1 && acc > 0.5) {
                if spawned < 160 { shedChunk(x: L.colX(i), y: L.baseY(i) - L.h[i], mass: acc, vx: vx, vy: vy, z: L.z, from: L.id) }
                spawned += 1
                acc = 0
            }
        }
    }

    /// Zavřené / minimalizované okno: všechno spadne najednou.
    private func dropAll(_ L: Ledge) {
        let snow = config.mode == .snow
        var acc: Float = 0
        var target: Float = snow ? rng.r(6, 22) : (config.mode == .leaves ? 15 : 5)
        var spawned = 0
        for i in 0..<L.n where L.h[i] > 0.05 && L.cap[i] >= 0 {
            acc += L.h[i] * dx
            L.h[i] = 0
            if acc >= target {
                if spawned < 220 {
                    if snow {
                        shedChunk(x: L.colX(i), y: L.baseY(i), mass: acc, vx: rng.r(-30, 30), vy: rng.r(0, 40), z: L.z)
                    } else {
                        spawnLoose(x: L.colX(i), y: L.baseY(i), mass: acc, vx: rng.r(-30, 30), vy: rng.r(0, 20), z: L.z)
                    }
                }
                spawned += 1
                acc = 0
                if snow { target = rng.r(6, 22) }
            }
        }
        L.mass = 0
        for b in L.beads { drip(x: Float(L.rect.minX) + b.x, y: Float(L.rect.minY) + b.y, vx: 0, vy: 0) }
        L.beads.removeAll()
        L.specks.removeAll()
        L.films.removeAll()
    }

    // MARK: Kurzor

    private func interact(_ m: SIMD2<Float>, dt: Float) {
        let speed = (mouseVel.x * mouseVel.x + mouseVel.y * mouseVel.y).squareRoot()
        if config.mode != .rain { carve(m) }
        if speed > 40 { pushAir(m) }
        if config.mode == .rain { smear(m, dt: dt, speed: speed) }
    }

    /// Kurzor je kruh: závěj pod ním se rozestoupí do stran a část se rozpráší.
    private func carve(_ m: SIMD2<Float>) {
        let R: Float = 9
        for L in ledges where L.mass > 0.01 {
            guard m.x + R >= L.x0, m.x - R <= L.x0 + Float(L.n) * dx else { continue }
            guard m.y + R >= L.y - L.maxPile - 2, m.y - R <= L.y + L.radius + 1 else { continue }
            let i0 = max(0, Int(((m.x - R - L.x0) / dx).rounded(.down)))
            let i1 = min(L.n - 1, Int(((m.x + R - L.x0) / dx).rounded(.up)))
            guard i0 <= i1 else { continue }
            var removedTotal: Float = 0
            var sprayX: Float = 0
            var sprayY: Float = 0
            for i in i0...i1 where L.cap[i] >= 0 && L.h[i] > 0.02 {
                let off = L.colX(i) - m.x
                guard abs(off) < R else { continue }
                let depth = (R * R - off * off).squareRoot()
                let by = L.baseY(i)
                let surf = by - L.h[i]
                let bottom = m.y + depth
                guard m.y - depth < by, bottom > surf else { continue }
                let newSurf = min(by, bottom)
                let removed = min(L.h[i], newSurf - surf)
                guard removed > 0.02 else { continue }
                L.h[i] -= removed
                // část se přesune těsně za okraj kruhu (rozhrnutí), zbytek odletí
                let side: Int = off < 0 ? -1 : 1
                let reach = Int(((R - abs(off)) / dx).rounded(.up)) + 1
                let j = i + side * reach
                if j >= 0 && j < L.n && L.cap[j] >= 0 {
                    let room = max(0, L.cap[j] - L.h[j])
                    let push = min(room, removed * 0.4)
                    L.h[j] += push
                    removedTotal += removed - push
                } else {
                    removedTotal += removed
                }
                sprayX = L.colX(i)
                sprayY = newSurf - 1
            }
            guard removedTotal > 0 else { continue }
            L.carved += removedTotal * dx
            let unit: Float = config.mode == .snow ? 1.4 : (config.mode == .leaves ? 9 : 3.5)
            var budget = L.carved
            var made = 0
            while budget >= unit && made < 30 {
                budget -= unit
                made += 1
                let vx = mouseVel.x * rng.r(0.25, 0.7) + rng.r(-40, 40)
                let vy = min(0, mouseVel.y * 0.3) - rng.r(50, 170)
                // jemný prášek se ve vzduchu z větší části rozplyne — rýha po kurzoru zůstane
                let carry: Float = config.mode == .snow ? 0.3 : 1
                spawnLoose(x: sprayX + rng.r(-R, R) * 0.6, y: sprayY, mass: unit * carry, vx: vx, vy: vy, z: L.z)
            }
            L.carved = budget
            L.mass = max(0, L.mass - removedTotal)
        }
    }

    private func pushAir(_ m: SIMD2<Float>) {
        let R: Float = 34
        let R2 = R * R
        for k in 0..<parts.count {
            let ddx = parts[k].x - m.x, ddy = parts[k].y - m.y
            let d2 = ddx * ddx + ddy * ddy
            guard d2 < R2 else { continue }
            let kind = parts[k].kind
            guard kind != PK.rain, kind != PK.splash else { continue }
            let f = (1 - d2.squareRoot() / R) * 0.35
            parts[k].ex += (mouseVel.x * 0.6 - parts[k].ex) * f
            parts[k].ey += (mouseVel.y * 0.6 - parts[k].ey) * f
        }
    }

    // MARK: Déšť na skle

    private func rainOnGlass(_ L: Ledge, x: Float) {
        let gx = x - Float(L.rect.minX)
        let gh = Float(L.rect.height)
        guard gh > 6 else { return }
        if rng.f() < 0.4 && L.specks.count < 240 {
            let life = rng.r(6, 14)
            L.specks.append(Speck(x: gx + rng.r(-7, 7), y: rng.r(1.5, min(38, gh - 2)),
                                  r: rng.r(0.5, 1.3), life: life, maxLife: life))
        }
        if rng.f() < 0.035 && L.beads.count < 28 {
            var b = Bead(x: gx, y: rng.r(1.5, 6), r: rng.r(1.5, 2.6))
            b.stuck = rng.r(0.2, 1.6)
            b.wob = rng.r(0, 6.283)
            L.beads.append(b)
        }
    }

    private func updateGlass(_ L: Ledge, dt: Float) {
        let gw = Float(L.rect.width), gh = Float(L.rect.height)
        var s = 0
        while s < L.specks.count {
            L.specks[s].life -= dt
            if L.specks[s].life <= 0 { L.specks.swapAt(s, L.specks.count - 1); L.specks.removeLast() } else { s += 1 }
        }
        var f = 0
        while f < L.films.count {
            L.films[f].life -= dt
            if L.films[f].life <= 0 { L.films.swapAt(f, L.films.count - 1); L.films.removeLast() } else { f += 1 }
        }
        var k = 0
        while k < L.beads.count {
            var b = L.beads[k]
            var remove = false
            if b.hanging {
                // visí pod spodní hranou a sbírá vodu, až se utrhne
                b.r += dt * 0.16
                b.wob += dt
                if b.r > 3.4 {
                    drip(x: Float(L.rect.minX) + b.x, y: Float(L.rect.maxY) + b.r, vx: 0, vy: 30)
                    remove = true
                }
            } else if b.stuck > 0 {
                b.stuck -= dt
                b.r = min(3.2, b.r + dt * 0.05)
            } else {
                let target = 26 + b.r * b.r * 13
                b.vy += (target - b.vy) * min(1, dt * 4)
                let dy = b.vy * dt
                b.y += dy
                b.x += sin(b.y * 0.13 + b.wob) * 0.12
                b.trail += dy
                if b.trail > 7 {
                    b.trail = 0
                    if L.films.count < 260 {
                        let life = rng.r(4, 7)
                        L.films.append(Film(x: b.x, y: b.y - 7, len: 8, w: b.r * 1.5, life: life, maxLife: life))
                    }
                    if b.r > 1.5 && L.specks.count < 260 {
                        let sr = b.r * rng.r(0.22, 0.34)
                        let life = rng.r(8, 16)
                        L.specks.append(Speck(x: b.x + rng.r(-0.6, 0.6), y: b.y - b.r - rng.r(1, 3),
                                              r: sr, life: life, maxLife: life))
                        b.r = max(0.8, cbrtf(b.r * b.r * b.r - sr * sr * sr))
                    }
                }
                // zachytí se o smítko, pak se zase utrhne
                if rng.f() < dy * 0.012 {
                    b.stuck = rng.r(0.15, 0.9)
                    b.vy = 0
                }
                // posbírá kapičky, přes které jede
                var j = 0
                while j < L.specks.count {
                    let sp = L.specks[j]
                    if abs(sp.x - b.x) < b.r + sp.r && sp.y > b.y - b.r - 1 && sp.y < b.y + b.r + 1 {
                        b.r = min(3.6, cbrtf(b.r * b.r * b.r + sp.r * sp.r * sp.r))
                        L.specks.swapAt(j, L.specks.count - 1)
                        L.specks.removeLast()
                    } else {
                        j += 1
                    }
                }
                if b.y + b.r >= gh {
                    b.y = gh
                    b.hanging = true
                }
                if b.r < 1.0 {
                    let life = rng.r(5, 10)
                    L.specks.append(Speck(x: b.x, y: b.y, r: b.r, life: life, maxLife: life))
                    remove = true
                }
            }
            if b.x < -2 || b.x > gw + 2 { remove = true }
            if remove {
                L.beads.swapAt(k, L.beads.count - 1)
                L.beads.removeLast()
            } else {
                L.beads[k] = b
                k += 1
            }
        }
    }

    private func drip(x: Float, y: Float, vx: Float, vy: Float) {
        guard parts.count < maxParticles() + 900 else { return }
        var q = Particle()
        q.kind = PK.drip
        q.x = x
        q.y = y
        q.ex = vx
        q.ey = vy
        q.size = rng.r(2.2, 3.2)
        q.depth = 1
        parts.append(q)
    }

    /// Prudce pohnuté okno: kapky odletí, drobné kapičky se rozprsknou.
    private func throwGlass(_ L: Ledge, vx: Float, vy: Float) {
        guard L.hasGlass else { return }
        let ox = Float(L.rect.minX), oy = Float(L.rect.minY)
        for b in L.beads {
            drip(x: ox + b.x, y: oy + b.y, vx: vx * 0.6 + rng.r(-20, 20), vy: vy * 0.6 - rng.r(0, 60))
        }
        for sp in L.specks where rng.f() < 0.3 {
            var q = Particle()
            q.kind = PK.splash
            q.x = ox + sp.x
            q.y = oy + sp.y
            q.ex = vx * 0.5 + rng.r(-40, 40)
            q.ey = vy * 0.5 - rng.r(20, 80)
            q.size = rng.r(0.8, 1.4)
            q.life = rng.r(0.3, 0.5)
            q.depth = 0.8
            parts.append(q)
        }
        L.beads.removeAll()
        L.specks.removeAll()
        L.films.removeAll()
    }

    /// Kurzor kapky rozmaže: postrčí je, setře drobné kapičky a nechá mokrou stopu.
    private func smear(_ m: SIMD2<Float>, dt: Float, speed: Float) {
        guard speed > 20 else { return }
        let R: Float = 10
        for L in ledges where L.kind != .ground && L.hasGlass {
            let lx = m.x - Float(L.rect.minX), ly = m.y - Float(L.rect.minY)
            guard lx > -R, ly > -R, lx < Float(L.rect.width) + R, ly < Float(L.rect.height) + R else { continue }
            var touched = false
            for k in 0..<L.beads.count {
                let ddx = L.beads[k].x - lx, ddy = L.beads[k].y - ly
                if ddx * ddx + ddy * ddy < (R + L.beads[k].r) * (R + L.beads[k].r) {
                    L.beads[k].x += mouseVel.x * dt * 0.85
                    L.beads[k].y += mouseVel.y * dt * 0.85
                    L.beads[k].stuck = 0
                    L.beads[k].hanging = false
                    touched = true
                }
            }
            var j = 0
            while j < L.specks.count {
                let ddx = L.specks[j].x - lx, ddy = L.specks[j].y - ly
                if ddx * ddx + ddy * ddy < R * R {
                    L.specks.swapAt(j, L.specks.count - 1)
                    L.specks.removeLast()
                    touched = true
                } else {
                    j += 1
                }
            }
            if touched && L.films.count < 260 {
                let life = rng.r(2.5, 4.5)
                L.films.append(Film(x: lx, y: ly, len: 10, w: 9, life: life, maxLife: life))
            }
        }
    }

    // MARK: Výběr na ploše (Deep Interaction)

    private func handleSelection(mouse: SIMD2<Float>?, down: Bool) {
        defer { wasDown = down }
        guard config.deep, config.mode != .rain, let m = mouse else {
            if !down, let s = selection {
                dropAll(s)
                selection = nil
                mapDirty = true
            }
            if !down { selectStart = nil }
            return
        }
        if down && !wasDown {
            let p = CGPoint(x: CGFloat(m.x), y: CGFloat(m.y))
            let onWindow = windowRects.contains { $0.contains(p) } || (dockRect?.contains(p) ?? false)
            selectStart = (!onWindow && m.y > topLimit + 2) ? m : nil
        }
        if down, let s = selectStart {
            let r = CGRect(x: CGFloat(min(s.x, m.x)), y: CGFloat(min(s.y, m.y)),
                           width: CGFloat(abs(m.x - s.x)), height: CGFloat(abs(m.y - s.y)))
            guard r.width > 8, r.height > 8 else { return }
            if let sel = selection {
                if sel.rect != r {
                    if abs(sel.rect.width - r.width) > 0.5 {
                        for (x, y, mass) in sel.layout(r) { spawnLoose(x: x, y: y, mass: mass, vx: 0, vy: 0) }
                    } else {
                        sel.move(to: r)
                    }
                    var all = windowRects
                    if let d = dockRect { all.append(d) }
                    sel.fronts = all.filter { $0.intersects(r.insetBy(dx: -1, dy: -40)) }
                    applyCaps(sel)
                    mapDirty = true
                }
            } else {
                let sel = Ledge(id: -3, kind: .selection, rect: r, radius: 0, maxPile: 18)
                var all = windowRects
                if let d = dockRect { all.append(d) }
                sel.fronts = all.filter { $0.intersects(r.insetBy(dx: -1, dy: -40)) }
                applyCaps(sel)
                selection = sel
                mapDirty = true
            }
        }
        if !down && wasDown {
            if let s = selection {
                dropAll(s)
                selection = nil
                mapDirty = true
            }
            selectStart = nil
        }
    }

    // MARK: Halloween

    private func ledge(id: Int) -> Ledge? {
        switch id {
        case -1: return ground
        case -2: return dockLedge
        default: return windowLedges[id]
        }
    }

    private func updateGhost() {
        if let g = ghost {
            let e = t - g.start
            if e > 5.6 || ledge(id: g.ledgeId) == nil {
                ghost = nil
                nextGhost = t + Double(rng.r(9, 22))
            } else if !g.popped && e > 0.12, let L = ledge(id: g.ledgeId), g.col < L.n {
                ghost?.popped = true
                let x = L.colX(g.col), y = L.baseY(g.col) - L.h[g.col]
                for _ in 0..<10 {
                    spawnLoose(x: x + rng.r(-10, 10), y: y, mass: 1, vx: rng.r(-60, 60), vy: -rng.r(60, 150))
                }
            }
            return
        }
        guard t >= nextGhost else { return }
        nextGhost = t + 3
        var candidates: [Ledge] = []
        if ground.mass > 30 && (config.ground) { candidates.append(contentsOf: [ground, ground, ground]) }
        for L in windowLedges.values where L.mass > 20 { candidates.append(L) }
        guard !candidates.isEmpty else { return }
        let L = candidates[rng.i(candidates.count)]
        for _ in 0..<14 {
            let i = 6 + rng.i(max(1, L.n - 12))
            guard i < L.n, L.cap[i] >= 60, L.h[i] >= 3, L.colX(i) > 30, L.colX(i) < W - 30 else { continue }
            let sprites: [Sprite] = [.ghostBoo, .ghostHalloween, .ghostTrick, .ghostBrrr]
            ghost = Ghost(ledgeId: L.id, col: i, start: t, sprite: sprites[rng.i(sprites.count)])
            return
        }
    }

    /// Diagnostika: hmota a profil výšek každé hrany.
    func debugSummary() -> String {
        var out = "particles \(parts.count)\n"
        for L in allLedges() {
            let vis = L.cap.filter { $0 >= 0 }.count
            let maxH = L.h.max() ?? 0
            let avg = L.h.reduce(0, +) / Float(max(1, L.n))
            let prof = stride(from: 0, to: L.n, by: max(1, L.n / 24)).map { String(format: "%.1f", L.h[$0]) }.joined(separator: " ")
            out += "\(L.kind) rect=\(L.rect) n=\(L.n) visible=\(vis) avg=\(String(format: "%.2f", avg)) max=\(String(format: "%.1f", maxH)) capMin=\(L.cap.min() ?? 0)\n  \(prof)\n"
        }
        return out
    }

    // MARK: - Kreslení

    func render(sprites sw: inout SpriteWriter, strips tw: inout StripWriter) -> (back: Int, colors: PileColors) {
        let tf = Float(t.truncatingRemainder(dividingBy: 10_000))
        let mode = config.mode
        let halloween = config.halloween && mode == .snow

        // --- zadní vrstva (pod závějí): dýně a duch vylézající ze sněhu ---
        if halloween {
            for L in ledges where L.kind == .ground || (L.kind == .window && L.rect.width >= 360) {
                let count = L.kind == .ground ? max(2, Int(W / 430)) : (hash01(L.id, 3) < 0.6 ? 1 : 0)
                for k in 0..<count {
                    let i = Int((0.1 + 0.8 * hash01(L.id &* 31 &+ k, 11)) * Float(L.n))
                    guard i >= 0 && i < L.n, L.cap[i] >= 30 else { continue }
                    let h = L.h[i]
                    let vis = smoothstep(0.6, 2.4, h)
                    guard vis > 0 else { continue }
                    let by = L.baseY(i)
                    let bottom = min(by, by - h + 6)
                    let s: Sprite = hash01(L.id, k &+ 77) < 0.3 ? .pumpkinWink : .pumpkin
                    sw.add(s, x: L.colX(i), y: bottom - 14, w: 32, h: 28, alpha: vis, mode: 1)
                }
            }
            if let g = ghost, let L = ledge(id: g.ledgeId), g.col < L.n {
                let e = Float(t - g.start)
                let rise: Float
                if e < 0.9 { rise = 1 - pow(1 - e / 0.9, 3) } else if e < 4.7 { rise = 1 } else { rise = max(0, 1 - (e - 4.7) / 0.9) }
                let surf = L.baseY(g.col) - L.h[g.col]
                let bob = sin(e * 2.6) * 2.5 * min(1, e)
                let bottom = surf + 4 + 64 * (1 - rise) - bob * rise
                sw.addClipped(g.sprite, cx: L.colX(g.col) + sin(e * 1.3) * 3, bottom: bottom, w: 56, h: 64,
                              clipY: surf + 2, alpha: 1)
            }
        }
        let back = sw.count

        // --- závěje ---
        let colors: PileColors
        var lower: Float = 0
        var haloA: Float = 0
        switch mode {
        case .snow, .rain:
            colors = PileColors(top: SIMD4(1, 1, 1, 1), deep: SIMD4(0.8, 0.85, 0.93, 14),
                                halo: SIMD4(0.42, 0.47, 0.55, 1))
            haloA = 0.24
        case .leaves:
            colors = PileColors(top: SIMD4(0.4, 0.22, 0.09, 1), deep: SIMD4(0.27, 0.15, 0.06, 10),
                                halo: SIMD4(0.2, 0.1, 0.05, 1))
            lower = 2.6
        case .blossom:
            colors = PileColors(top: SIMD4(0.98, 0.8, 0.86, 1), deep: SIMD4(0.88, 0.64, 0.72, 8),
                                halo: SIMD4(0.6, 0.45, 0.5, 1))
            lower = 1.4
            haloA = 0.12
        }
        if mode != .rain {
            for L in ledges where L.mass > 0.02 {
                buildPile(L, &tw, lower: lower, haloA: haloA)
            }
            if mode == .leaves || mode == .blossom {
                for L in ledges where L.mass > 0.3 { buildHeap(L, &sw, leaves: mode == .leaves) }
            }
            if mode == .snow {
                for L in ledges where L.mass > 0.3 { sparkles(L, &sw, tf: tf) }
            }
            if halloween {
                for L in ledges where L.kind == .ground || (L.kind == .window && L.rect.width >= 360) {
                    let count = L.kind == .ground ? max(2, Int(W / 430)) : (hash01(L.id, 3) < 0.6 ? 1 : 0)
                    for k in 0..<count {
                        let i = Int((0.1 + 0.8 * hash01(L.id &* 31 &+ k, 11)) * Float(L.n))
                        guard i >= 0 && i < L.n, L.cap[i] >= 30 else { continue }
                        let h = L.h[i]
                        let vis = smoothstep(0.6, 2.4, h)
                        guard vis > 0 else { continue }
                        let by = L.baseY(i)
                        let bottom = min(by, by - h + 6)
                        let fk = Float(k)
                        let flicker = 0.78 + 0.22 * sin(tf * 13 + fk) * sin(tf * 7.3 + 2 * fk)
                        sw.add(.glow, x: L.colX(i), y: bottom - 12, w: 58, h: 50, alpha: 0.34 * flicker * vis,
                               mode: 2, r: 1, g: 0.55, b: 0.16)
                    }
                }
            }
        } else {
            for L in ledges where L.kind != .ground && L.hasGlass { buildGlass(L, &sw) }
        }

        // --- padající částice ---
        for p in parts {
            guard p.x > -20, p.x < W + 20, p.y > -40, p.y < H + 20 else { continue }
            switch p.kind {
            case PK.flake:
                sw.add(Sprite(rawValue: Int(p.sprite)) ?? .flakeSoft, x: p.x, y: p.y, w: p.size, h: p.size,
                       rot: p.rot, alpha: 0.5 + 0.5 * p.depth, r: 0.98, g: 0.99, b: 1)
            case PK.powder:
                let a = p.life < 0.6 ? max(0, p.life / 0.6) : 1
                sw.add(.flakeSoft, x: p.x, y: p.y, w: p.size, h: p.size, alpha: 0.9 * a, r: 0.98, g: 0.99, b: 1)
            case PK.lump:
                sw.add(.flakeFluffy, x: p.x, y: p.y, w: p.size, h: p.size, rot: p.rot, alpha: 1, r: 0.97, g: 0.98, b: 1)
            case PK.leaf:
                let c = leafTints[Int(p.tint) % leafTints.count]
                let fl = cos(p.flip)
                sw.add(Sprite(rawValue: Int(p.sprite)) ?? .leafOval, x: p.x, y: p.y,
                       w: p.size * max(0.16, abs(fl)), h: p.size, rot: p.rot, alpha: 1,
                       r: c.0 * (0.8 + 0.2 * abs(fl)), g: c.1 * (0.8 + 0.2 * abs(fl)), b: c.2, hi: 0.12 * abs(sin(p.flip)))
            case PK.petal:
                let c = petalTints[Int(p.tint) % petalTints.count]
                let fl = cos(p.flip)
                let glint = 0.12 + 0.75 * pow(max(0, sin(p.flip)), 6)
                sw.add(Sprite(rawValue: Int(p.sprite)) ?? .petal, x: p.x, y: p.y,
                       w: p.size * max(0.18, abs(fl)), h: p.size, rot: p.rot, alpha: 1,
                       r: c.0, g: c.1, b: c.2, hi: glint)
            case PK.flower:
                sw.add(.flower, x: p.x, y: p.y, w: 18, h: 26, rot: p.rot, alpha: 1, mode: 1)
            case PK.rain:
                let len = 12 + 14 * p.size
                let vx = wind() * 1.8 + p.ex
                sw.add(.streak, x: p.x, y: p.y - len * 0.4, w: 0.7 + 0.9 * p.size, h: len,
                       rot: atan2(-vx, p.fall), alpha: 0.22 + 0.36 * p.size, r: 0.84, g: 0.9, b: 0.98)
            case PK.drip:
                sw.add(.bead, x: p.x, y: p.y, w: p.size * 1.6, h: p.size * 2.2, alpha: 0.85,
                       r: 0.86, g: 0.9, b: 0.98, hi: 1)
            default: // splash
                let a = max(0, p.life / 0.4)
                sw.add(.dot, x: p.x, y: p.y, w: p.size, h: p.size, alpha: 0.55 * a * (0.5 + 0.5 * p.depth),
                       r: 0.86, g: 0.9, b: 1)
            }
        }
        return (back, colors)
    }

    /// Tělo závěje + jemný stín nad povrchem (aby byla vidět i na bílém).
    /// Prázdné úseky se vynechají — vrcholy jen tam, kde něco leží.
    private func buildPile(_ L: Ledge, _ tw: inout StripWriter, lower: Float, haloA: Float) {
        let n = L.n
        tw.end()
        var prevH: Float = -1          // -1: žádný předchozí viditelný sloupec
        var zx: Float = 0, zy: Float = 0
        for i in 0..<n {
            let x = L.colX(i)
            guard L.cap[i] >= 0, x > -dx, x < W + dx else {
                tw.end()
                prevH = -1
                continue
            }
            let hm = i > 0 && L.cap[i - 1] >= 0 ? L.h[i - 1] : L.h[i]
            let hp = i < n - 1 && L.cap[i + 1] >= 0 ? L.h[i + 1] : L.h[i]
            let hs = max(0, (hm + 2 * L.h[i] + hp) * 0.25 - lower)
            let by = L.baseY(i)
            if hs < 0.03 {
                if prevH > 0.03 {
                    tw.column(x: x, top: by, base: by, halo: 0)
                    tw.end()
                }
                prevH = 0
                zx = x
                zy = by
                continue
            }
            if prevH == 0 { tw.column(x: zx, top: zy, base: zy, halo: 0) }
            tw.column(x: x, top: by - hs, base: by, halo: haloA * min(1, hs / 2))
            prevH = hs
        }
        tw.end()
    }

    /// Hromádka je vidět, že je z listů: listy vrstvené podle výšky sloupce.
    private func buildHeap(_ L: Ledge, _ sw: inout SpriteWriter, leaves: Bool) {
        let layer: Float = leaves ? 3.2 : 2.2
        let melt = config.melt
        var i = 0
        while i < L.n {
            defer { i += 2 }
            guard L.cap[i] >= 0 else { continue }
            let h = max(L.h[i], i + 1 < L.n ? L.h[i + 1] : 0)
            guard h > 0.4 else { continue }
            let by = L.baseY(i)
            let x = L.colX(i) + dx * 0.5
            let layers = min(16, Int(h / layer) + 1)
            let age = melt ? L.age[i] : 0
            for k in 0..<layers {
                let frac = min(1, (h - Float(k) * layer) / layer)
                guard frac > 0.35 else { continue }
                let h1 = hash01(L.id &* 7919 &+ i, k)
                let h2 = hash01(i &* 131 &+ k, L.id)
                let h3 = hash01(k &* 977 &+ i, 5)
                let yy = by - Float(k) * layer - layer * 0.55 - h1 * 1.2
                let xx = x + (h2 - 0.5) * 7
                if leaves {
                    let c = leafTints[Int(h3 * 8) % leafTints.count]
                    let size = (9 + h1 * 6) * (1 - 0.2 * min(1, age))
                    let s = leafSprites[Int(h2 * 4) % 4]
                    let shade: Float = 0.78 + 0.22 * h3
                    sw.add(s, x: xx, y: yy, w: size, h: size * (0.5 + 0.3 * h3), rot: (h1 - 0.5) * 1.3 + (h2 < 0.5 ? 1.57 : 0),
                           alpha: min(1, frac * 2.2), extra: min(1, age * 0.8),
                           r: c.0 * shade, g: c.1 * shade, b: c.2 * shade)
                } else {
                    let c = petalTints[Int(h3 * 5) % petalTints.count]
                    let size = 5.5 + h1 * 3
                    sw.add(h2 < 0.5 ? .petal : .petalCurled, x: xx, y: yy, w: size, h: size * (0.6 + 0.3 * h3),
                           rot: (h1 - 0.5) * 2.4, alpha: min(1, frac * 2.2), extra: min(1, age * 0.9),
                           r: c.0, g: c.1, b: c.2, hi: 0.1 + 0.2 * h2)
                }
            }
        }
    }

    private func sparkles(_ L: Ledge, _ sw: inout SpriteWriter, tf: Float) {
        for i in 0..<L.n where L.cap[i] >= 0 && L.h[i] > 1.2 {
            let hsh = hash01(L.id &+ 1000, i)
            guard hsh < 0.07 else { continue }
            let h2 = hash01(i, L.id &+ 2000)
            let s = sin(tf * (1.2 + 1.6 * h2) + h2 * 40)
            let a = pow(max(0, s), 30)
            guard a > 0.02 else { continue }
            let y = L.baseY(i) - L.h[i] + 1 + hsh * 10 * min(L.h[i] - 1, 5)
            sw.add(.sparkle, x: L.colX(i) + (h2 - 0.5) * 2, y: y, w: 4.5, h: 4.5, alpha: a * 0.9)
        }
    }

    private func buildGlass(_ L: Ledge, _ sw: inout SpriteWriter) {
        let ox = Float(L.rect.minX), oy = Float(L.rect.minY)
        func hidden(_ x: Float, _ y: Float) -> Bool {
            if x < 0 || x > W || y < 0 || y > H { return true }
            for f in L.fronts where Float(f.minX) <= x && x <= Float(f.maxX) && Float(f.minY) <= y && y <= Float(f.maxY) {
                return true
            }
            return false
        }
        for f in L.films {
            let x = ox + f.x, y = oy + f.y
            guard !hidden(x, y) else { continue }
            sw.add(.dot, x: x, y: y, w: f.w, h: f.len * 1.6, alpha: 0.08 * f.life / f.maxLife, r: 0.88, g: 0.92, b: 1)
        }
        for s in L.specks {
            let x = ox + s.x, y = oy + s.y
            guard !hidden(x, y) else { continue }
            let a = min(1, s.life / min(2, s.maxLife))
            sw.add(.bead, x: x, y: y, w: s.r * 2, h: s.r * 2, alpha: 0.6 * a, r: 0.88, g: 0.92, b: 1, hi: 0.9)
        }
        for b in L.beads {
            let x = ox + b.x
            let y: Float
            let w: Float, h: Float
            if b.hanging {
                y = oy + b.y + b.r * 0.75
                w = b.r * 2
                h = b.r * 2.3 + sin(b.wob * 3) * 0.2
            } else {
                y = oy + b.y
                w = b.r * 2
                h = b.r * (b.stuck > 0 ? 2.05 : 2.3)
            }
            guard !hidden(x, b.hanging ? oy + b.y - 1 : y) else { continue }
            sw.add(.bead, x: x, y: y, w: w, h: h, alpha: 0.82, r: 0.86, g: 0.9, b: 0.98, hi: 1)
        }
    }
}

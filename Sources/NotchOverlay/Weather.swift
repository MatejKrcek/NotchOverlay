import AppKit
import ApplicationServices
import IOKit.ps
import QuartzCore

// Počasí na ploše: sníh, podzimní listí, déšť, třešňový květ (+ Halloween).
// Průhledné okno přes každou obrazovku, kliky propouští; sníh se usazuje
// na zemi, Docku, horních hranách oken a widgetech.

enum WeatherMode: String, CaseIterable {
    case snow, leaves, rain, blossom

    var title: String {
        switch self {
        case .snow: return "Snow"
        case .leaves: return "Autumn Leaves"
        case .rain: return "Rain"
        case .blossom: return "Cherry Blossom"
        }
    }

    var meltTitle: String {
        switch self {
        case .leaves: return "Wither leaves"
        case .blossom: return "Wilt petals"
        default: return "Melt snow"
        }
    }

    var clearTitle: String {
        switch self {
        case .leaves: return "Clear Leaves"
        case .blossom: return "Clear Petals"
        default: return "Clear Snow"
        }
    }
}

enum WeatherIntensity: String, CaseIterable {
    case light, steady, heavy, variable

    var title: String { rawValue.capitalized }
}

/// Uložené volby (UserDefaults). Negované klíče („No…") = výchozí zapnuto.
enum WeatherPrefs {
    private static var d: UserDefaults { .standard }

    static var enabled: Bool {
        get { d.bool(forKey: "weatherEnabled") }
        set { d.set(newValue, forKey: "weatherEnabled") }
    }
    static var mode: WeatherMode {
        get { WeatherMode(rawValue: d.string(forKey: "weatherMode") ?? "") ?? .snow }
        set { d.set(newValue.rawValue, forKey: "weatherMode") }
    }
    /// Halloween i mimo 30. 10. – 1. 11. (jen ke sněhu).
    static var halloween: Bool {
        get { d.bool(forKey: "weatherHalloween") }
        set { d.set(newValue, forKey: "weatherHalloween") }
    }
    static var intensity: WeatherIntensity {
        get { WeatherIntensity(rawValue: d.string(forKey: "weatherIntensity") ?? "") ?? .steady }
        set { d.set(newValue.rawValue, forKey: "weatherIntensity") }
    }
    static var opacity: Double {
        get { let v = d.double(forKey: "weatherOpacity"); return v == 0 ? 0.9 : v }
        set { d.set(newValue, forKey: "weatherOpacity") }
    }
    static var onGround: Bool {
        get { !d.bool(forKey: "weatherNoGround") }
        set { d.set(!newValue, forKey: "weatherNoGround") }
    }
    static var onDock: Bool {
        get { !d.bool(forKey: "weatherNoDock") }
        set { d.set(!newValue, forKey: "weatherNoDock") }
    }
    static var onWindows: Bool {
        get { !d.bool(forKey: "weatherNoWindows") }
        set { d.set(!newValue, forKey: "weatherNoWindows") }
    }
    static var onWidgets: Bool {
        get { !d.bool(forKey: "weatherNoWidgets") }
        set { d.set(!newValue, forKey: "weatherNoWidgets") }
    }
    static var melt: Bool {
        get { !d.bool(forKey: "weatherNoMelt") }
        set { d.set(!newValue, forKey: "weatherNoMelt") }
    }
    static var deepInteraction: Bool {
        get { d.bool(forKey: "weatherDeepInteraction") }
        set { d.set(newValue, forKey: "weatherDeepInteraction") }
    }
    static var behindWindows: Bool {
        get { d.bool(forKey: "weatherBehindWindows") }
        set { d.set(newValue, forKey: "weatherBehindWindows") }
    }
    static var overFullScreen: Bool {
        get { d.bool(forKey: "weatherOverFullScreen") }
        set { d.set(newValue, forKey: "weatherOverFullScreen") }
    }
    static var showInScreenshots: Bool {
        get { d.bool(forKey: "weatherShowInScreenshots") }
        set { d.set(newValue, forKey: "weatherShowInScreenshots") }
    }
    static var maxPerformance: Bool {
        get { d.bool(forKey: "weatherMaxPerformance") }
        set { d.set(newValue, forKey: "weatherMaxPerformance") }
    }

    /// 30. října až do svítání 1. listopadu.
    static func isHalloweenSeason(_ date: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        guard let m = c.month, let day = c.day, let hour = c.hour else { return false }
        return (m == 10 && day >= 30) || (m == 11 && day == 1 && hour < 6)
    }
}

enum WeatherLog {
    private static let path = NSString(string: "~/.claude/vibe-weather-debug.txt").expandingTildeInPath

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Controller

final class WeatherController {
    static let shared = WeatherController()

    private var overlays: [WeatherOverlay] = []
    /// GPU prostředky jen po dobu, kdy počasí běží (po vypnutí se uvolní).
    private var gpu: WeatherGPU?
    private let tracker = WindowTracker()
    private var started = false
    private var asleep = false
    private var locked = false
    private var saver = false
    private var lastPoll: CFTimeInterval = 0
    private var fastUntil: CFTimeInterval = 0
    private var dockRefreshAt: CFTimeInterval = 0
    private var lastPowerCheck: CFTimeInterval = 0
    private var lastHalloweenCheck: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var onBattery = false
    private var lowPowerMode = false
    private var halloweenSeason = false
    private var lastSnapshotTime: CFTimeInterval = 0

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.updatePause()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.updatePause()
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let now = CACurrentMediaTime()
            self?.overlays.forEach { $0.sim.noteSpaceChange(now: now) }
            self?.fastUntil = now + 1
        }
        // Dock mění šířku, když se appka spustí nebo skončí — jen tehdy ho číst znovu
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.dockRefreshAt = CACurrentMediaTime() + 0.8
            }
        }
        let dn = DistributedNotificationCenter.default()
        let pairs: [(String, (WeatherController) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.locked = true }),
            ("com.apple.screenIsUnlocked", { $0.locked = false }),
            ("com.apple.screensaver.didstart", { $0.saver = true }),
            ("com.apple.screensaver.didstop", { $0.saver = false }),
        ]
        for (name, apply) in pairs {
            dn.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                apply(self)
                self.updatePause()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, WeatherPrefs.enabled else { return }
            // obrazovky se změnily: postavit znovu (krátce počkat, až se usadí)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.rebuild() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshPower()
        }
        tracker.onSnapshot = { [weak self] snap in self?.apply(snap) }
        refreshPower()
        halloweenSeason = WeatherPrefs.isHalloweenSeason()
        apply()
    }

    /// Po změně voleb v nastavení.
    func prefsChanged() {
        apply()
    }

    func clear() {
        overlays.forEach { $0.sim.clearAll() }
    }

    func debugSummary() -> String {
        overlays.map { $0.sim.debugSummary() }.joined(separator: "\n")
    }

    private func apply() {
        if WeatherPrefs.enabled {
            if overlays.isEmpty { rebuild() } else { overlays.forEach { $0.configure(config(), frame: frameSettings()) } }
        } else {
            teardown()
            gpu = nil
        }
    }

    private func config() -> WeatherConfig {
        var c = WeatherConfig()
        c.mode = WeatherPrefs.mode
        c.halloween = c.mode == .snow && (WeatherPrefs.halloween || halloweenSeason)
        c.intensity = WeatherPrefs.intensity
        c.opacity = Float(WeatherPrefs.opacity)
        c.ground = WeatherPrefs.onGround
        c.dock = WeatherPrefs.onDock
        c.windows = WeatherPrefs.onWindows
        c.widgets = WeatherPrefs.onWidgets
        c.melt = WeatherPrefs.melt
        c.deep = WeatherPrefs.deepInteraction
        c.lowPower = (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled) && !WeatherPrefs.maxPerformance
        return c
    }

    /// Snímky za sekundu a rozlišení kreslení. Výchozí je úsporné: 30 fps
    /// (v Low Power Mode 20) a poloviční rozlišení na Retině — měkké vločky
    /// a závěje se tím nezhorší, paměť pro snímky klesne na čtvrtinu.
    /// Max performance: plná frekvence displeje a plné rozlišení.
    private func frameSettings() -> WeatherOverlay.FrameSettings {
        let env = ProcessInfo.processInfo.environment
        var fs = WeatherOverlay.FrameSettings(fps: 30, idleFPS: 20, nativeResolution: false)
        if WeatherPrefs.maxPerformance {
            fs = .init(fps: 0, idleFPS: 0, nativeResolution: true)
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            fs.fps = 20
        }
        if let f = env["WEATHER_FPS"], let v = Int(f) { fs.fps = v; fs.idleFPS = v }
        if env["WEATHER_NATIVE"] != nil { fs.nativeResolution = true }
        return fs
    }

    private func rebuild() {
        teardown()
        guard WeatherPrefs.enabled else { return }
        if gpu == nil { gpu = WeatherGPU() }
        guard let gpu else {
            WeatherLog.write("metal unavailable — weather off")
            return
        }
        let cfg = config()
        let fs = frameSettings()
        for screen in NSScreen.screens {
            if let o = WeatherOverlay(screen: screen, gpu: gpu, config: cfg, frame: fs) { overlays.append(o) }
        }
        WeatherLog.write("on: \(overlays.count) screen(s), mode \(cfg.mode.rawValue), AX \(AXIsProcessTrusted())")
        lastPoll = 0
        requestPoll(dockFresh: true)
        updatePause()
    }

    private func teardown() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    private func updatePause() {
        let paused = asleep || locked || saver
        overlays.forEach { $0.setPaused(paused) }
    }

    private func refreshPower() {
        var battery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            battery = (type as String) == kIOPSBatteryPowerValue
        }
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard battery != onBattery || lpm != lowPowerMode else { return }
        onBattery = battery
        lowPowerMode = lpm
        // baterie a Low Power Mode mění počty částic a snímky — přenastavit
        overlays.forEach { $0.configure(config(), frame: frameSettings()) }
    }

    /// Okna se právě hýbou (tažení myší, pohyb zachycený v posledním odečtu).
    func windowsActive(_ now: CFTimeInterval) -> Bool { now < fastUntil }

    /// Volá každý snímek (stačí jednou za snímek pro všechny obrazovky).
    /// Okna se čtou svižně jen při tažení myší nebo těsně po pohybu okna.
    func frameTick(now: CFTimeInterval, mouseDown: Bool) {
        guard now - lastTick > 0.008 else { return }
        lastTick = now
        if now - lastPowerCheck > 30 {
            lastPowerCheck = now
            refreshPower()
        }
        if now - lastHalloweenCheck > 60 {
            lastHalloweenCheck = now
            let season = WeatherPrefs.isHalloweenSeason()
            if season != halloweenSeason {
                halloweenSeason = season
                overlays.forEach { $0.configure(config(), frame: frameSettings()) }
            }
        }
        if mouseDown { fastUntil = now + 0.6 }
        let interval: CFTimeInterval = now < fastUntil ? 1.0 / 30 : 0.5
        if now - lastPoll >= interval {
            let dock = dockRefreshAt > 0 && now >= dockRefreshAt
            if dock { dockRefreshAt = 0 }
            requestPoll(dockFresh: dock)
        }
    }

    private func requestPoll(dockFresh: Bool) {
        lastPoll = CACurrentMediaTime()
        tracker.request(dockFresh: dockFresh)
    }

    private func apply(_ snap: WindowSnapshot) {
        let pollDt = lastSnapshotTime > 0 ? snap.time - lastSnapshotTime : 0.5
        lastSnapshotTime = snap.time
        if snap.moved { fastUntil = max(fastUntil, CACurrentMediaTime() + 0.6) }
        overlays.forEach { $0.apply(snap, pollDt: pollDt) }
    }
}

// MARK: - Overlay jedné obrazovky

/// Vrstva pro Metal bez MTKView (žádné vlastní vlákno display linku).
private final class WeatherLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isOpaque: Bool { false }
}

final class WeatherOverlay: NSObject {
    struct FrameSettings: Equatable {
        /// Snímky za sekundu, když se něco hýbe rychle (kurzor v závěji, tažené okno,
        /// hroudy, déšť). 0 = plná frekvence displeje.
        var fps: Int
        /// Klidné sněžení: stačí méně snímků.
        var idleFPS: Int
        var nativeResolution: Bool
    }

    let sim: WeatherSim
    private let window: NSWindow
    private let view: WeatherLayerView
    private let metal: CAMetalLayer
    private let renderer: WeatherRenderer
    private let frameCG: CGRect
    private let frameNS: NSRect
    private let backingScale: CGFloat
    private let maxFPS: Int
    private let topLimit: Float
    private var lastTime: CFTimeInterval = 0
    private var paused = false
    private var occluded = false
    private var running = false
    private var config: WeatherConfig
    private var frameSettings: FrameSettings
    private var occlusionObserver: NSObjectProtocol?
    // smyčka snímků: CADisplayLink (macOS 14+), jinak Timer
    private var link: AnyObject?
    private var timer: Timer?
    private var linkFPS = 0
    private var lastMouse: NSPoint?
    private var busyUntil: CFTimeInterval = 0

    init?(screen: NSScreen, gpu: WeatherGPU, config: WeatherConfig, frame fs: FrameSettings) {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        frameCG = CGDisplayBounds(displayID)
        frameNS = screen.frame
        backingScale = screen.backingScaleFactor
        maxFPS = max(30, screen.maximumFramesPerSecond)
        renderer = WeatherRenderer(gpu: gpu)
        self.config = config
        frameSettings = fs
        let menuBar = Float(max(0, screen.frame.maxY - screen.visibleFrame.maxY))
        topLimit = max(menuBar, Float(screen.safeAreaInsets.top))
        sim = WeatherSim(width: Float(frameNS.width), height: Float(frameNS.height))
        sim.config = config

        window = NSWindow(contentRect: frameNS, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        view = WeatherLayerView(frame: NSRect(origin: .zero, size: frameNS.size))
        metal = view.layer as! CAMetalLayer
        metal.device = gpu.device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = false
        // při ≤ 30 fps stačí dva snímky v zásobě (každý na Retině 22 MB)
        metal.maximumDrawableCount = 2
        metal.allowsNextDrawableTimeout = true
        super.init()
        window.contentView = view
        window.setFrame(frameNS, display: false)
        applyWindowOptions()
        applyFrameSettings()
        sim.prewarm()
        window.orderFrontRegardless()

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.occluded = !self.window.occlusionState.contains(.visible)
            self.updateRunning()
        }
        updateRunning()
    }

    func close() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        stopLoop()
        window.orderOut(nil)
        window.close()
    }

    func configure(_ c: WeatherConfig, frame fs: FrameSettings) {
        let old = config
        config = c
        sim.config = c
        if old.mode != c.mode { sim.modeChanged() }
        if old.ground != c.ground || old.dock != c.dock || old.windows != c.windows || old.widgets != c.widgets
            || old.mode != c.mode {
            sim.accumulationChanged()
        }
        applyWindowOptions()
        if fs != frameSettings {
            frameSettings = fs
            applyFrameSettings()
            if running {
                stopLoop()
                startLoop()
            }
        }
    }

    private func applyWindowOptions() {
        if WeatherPrefs.behindWindows {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        } else {
            // nad okny i Dockem, pod menu barem a islandem
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        }
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if WeatherPrefs.overFullScreen { behavior.insert(.fullScreenAuxiliary) }
        window.collectionBehavior = behavior
        window.sharingType = WeatherPrefs.showInScreenshots ? .readOnly : .none
    }

    private func applyFrameSettings() {
        let scale = frameSettings.nativeResolution ? backingScale : 1
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: frameNS.width * scale, height: frameNS.height * scale)
    }

    private var fps: Int { frameSettings.fps == 0 ? maxFPS : min(frameSettings.fps, maxFPS) }
    private var idleFPS: Int { frameSettings.idleFPS == 0 ? maxFPS : min(frameSettings.idleFPS, fps) }

    private func startLoop() {
        guard link == nil, timer == nil else { return }
        lastTime = 0
        if #available(macOS 14.0, *) {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            linkFPS = 0
            setLinkFPS(fps)
        } else {
            let t = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in self?.frame() }
            t.tolerance = 0.002
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Frekvence display linku (mění se za běhu podle toho, co se na obrazovce děje).
    private func setLinkFPS(_ f: Int) {
        guard f != linkFPS else { return }
        linkFPS = f
        if #available(macOS 14.0, *), let l = link as? CADisplayLink {
            let v = Float(f)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: v, maximum: v, preferred: v)
        }
    }

    private func stopLoop() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick(_ sender: Any) { frame() }

    func setPaused(_ p: Bool) {
        paused = p
        updateRunning()
    }

    private func updateRunning() {
        let run = !paused && !occluded
        guard run != running else { return }
        running = run
        if run { startLoop() } else { stopLoop() }
    }

    func apply(_ snap: WindowSnapshot, pollDt: Double) {
        let bounds = CGRect(origin: .zero, size: frameCG.size)
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -frameCG.minX, dy: -frameCG.minY) }
        var wins: [LocalWindow] = []
        for w in snap.windows {
            let r = local(w.rect)
            if r.intersects(bounds) { wins.append(LocalWindow(id: w.id, rect: r)) }
        }
        var widgets: [LocalWindow] = []
        for w in snap.widgets {
            let r = local(w.rect)
            if r.intersects(bounds) { widgets.append(LocalWindow(id: w.id, rect: r)) }
        }
        var dock: CGRect?
        if let d = snap.dock {
            let r = local(d)
            if r.intersects(bounds), r.minY < bounds.maxY - 4 { dock = r.intersection(bounds) }
        }
        sim.setScene(windows: wins, widgets: widgets, dock: dock, topLimit: topLimit,
                     now: CACurrentMediaTime(), pollDt: pollDt, closed: snap.closed)
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / Double(fps) : now - lastTime
        lastTime = now
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        WeatherController.shared.frameTick(now: now, mouseDown: down)

        let m = NSEvent.mouseLocation
        var mouse: SIMD2<Float>?
        if frameNS.contains(m) {
            mouse = SIMD2(Float(m.x - frameNS.minX), Float(frameNS.maxY - m.y))
        }
        let moved = lastMouse.map { abs($0.x - m.x) + abs($0.y - m.y) > 0.5 } ?? false
        lastMouse = m
        sim.step(dt: Float(dt), mouse: mouse, mouseDown: down)

        // plynule jen když je co sledovat, jinak úsporně
        if down || sim.animating || WeatherController.shared.windowsActive(now)
            || (moved && mouse.map { sim.cursorNearPile($0) } == true) {
            busyUntil = now + 0.8
        }
        setLinkFPS(now < busyUntil ? fps : idleFPS)

        let opacity = config.opacity
        renderer.draw(layer: metal, viewSize: frameNS.size) { sw, tw in
            let r = sim.render(sprites: &sw, strips: &tw)
            return (r.back, r.colors, opacity)
        }
    }
}

// MARK: - Sledování oken (na pozadí)

struct TrackedWindow {
    let id: Int
    let rect: CGRect
}

struct WindowSnapshot {
    let windows: [TrackedWindow]   // odpředu dozadu
    let widgets: [TrackedWindow]
    let dock: CGRect?
    let time: CFTimeInterval
    let moved: Bool
    /// Okna, která od minula zmizela a už neexistují (zavřená).
    let closed: Set<Int>
}

final class WindowTracker {
    var onSnapshot: ((WindowSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "notchoverlay.weather.windows", qos: .userInitiated)
    private var inFlight = false
    // jen na `queue`:
    private var dockRect: CGRect?
    private var lastDock: CFTimeInterval = 0
    private var lastRects: [Int: CGRect] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func request(dockFresh: Bool) {
        guard !inFlight else { return }
        inFlight = true
        // NSScreen jen z hlavního vlákna; záložní odhad Docku ho potřebuje
        let main = NSScreen.screens.first.map { ($0.frame, $0.visibleFrame) }
        queue.async { [weak self] in
            guard let self else { return }
            let snap = self.capture(dockFresh: dockFresh, mainScreen: main)
            DispatchQueue.main.async {
                self.inFlight = false
                self.onSnapshot?(snap)
            }
        }
    }

    private func capture(dockFresh: Bool, mainScreen: (NSRect, NSRect)?) -> WindowSnapshot {
        let now = CACurrentMediaTime()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [TrackedWindow] = []
        var widgets: [TrackedWindow] = []
        var rects: [Int: CGRect] = [:]
        let desktopIcon = Int(CGWindowLevelForKey(.desktopIconWindow))
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd) else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05, rect.width >= 60, rect.height >= 30 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            if layer >= 0 && layer < 20 {
                // vlastní overlaye mají level nad Dockem, sem nespadnou; nastavení appky ano
                windows.append(TrackedWindow(id: num, rect: rect))
                rects[num] = rect
            } else if layer < 0 && layer > desktopIcon && pid != ownPID
                        && (owner.contains("Notification") || owner.contains("Widget")) {
                // widgety na ploše (macOS 14+)
                if rect.width < 1200 && rect.height < 1000 { widgets.append(TrackedWindow(id: num, rect: rect)) }
            }
        }
        if dockFresh || now - lastDock > 15 {
            lastDock = now
            dockRect = Self.queryDock(mainScreen: mainScreen)
        }
        var moved = false
        for (id, r) in rects {
            if let old = lastRects[id], old != r { moved = true; break }
        }
        // zmizelá okna: existují ještě (minimalizovaná, jiný Space), nebo jsou zavřená?
        var closed = Set<Int>()
        let vanished = lastRects.keys.filter { rects[$0] == nil }
        if !vanished.isEmpty {
            // CFArray s holými CGWindowID (ne CFNumber) — tak to API chce
            var ptrs: [UnsafeRawPointer?] = vanished.map { UnsafeRawPointer(bitPattern: UInt($0)) }
            let arr = CFArrayCreate(nil, &ptrs, ptrs.count, nil)
            let desc = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] ?? []
            let alive = Set(desc.compactMap { $0[kCGWindowNumber as String] as? Int })
            closed = Set(vanished.filter { !alive.contains($0) })
            moved = true
        }
        lastRects = rects
        return WindowSnapshot(windows: windows, widgets: widgets, dock: dockRect, time: now, moved: moved,
                              closed: closed)
    }

    /// Rámeček Docku: přes Accessibility (AXList Docku), jinak odhad z nastavení Docku.
    private static func queryDock(mainScreen: (NSRect, NSRect)?) -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        if AXIsProcessTrusted() {
            let ax = AXUIElementCreateApplication(dock.processIdentifier)
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr {
                    var role: CFTypeRef?
                    AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role)
                    guard (role as? String) == "AXList" else { continue }
                    var pos: CFTypeRef?, size: CFTypeRef?
                    AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos)
                    AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &size)
                    var p = CGPoint.zero, s = CGSize.zero
                    if let pos, CFGetTypeID(pos) == AXValueGetTypeID() { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
                    if let size, CFGetTypeID(size) == AXValueGetTypeID() { AXValueGetValue(size as! AXValue, .cgSize, &s) }
                    if s.width > 20 && s.height > 20 { return glass(around: CGRect(origin: p, size: s)) }
                }
            }
        }
        return estimateDock(mainScreen: mainScreen)
    }

    /// Na macOS 26+ začíná skleněné pozadí Docku o kousek níž než seznam ikon (AXList);
    /// do stran sedí. Sníh má ležet na skle, ne ve vzduchu nad ním.
    /// Změřeno pro velikost ikon 45 pt: horní hrana skla +5 pt.
    private static func glass(around list: CGRect) -> CGRect {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return list }
        let tile = CGFloat(UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 48).clamped(16, 128)
        let top = (tile * 0.11).rounded()
        return CGRect(x: list.minX, y: list.minY + top, width: list.width, height: list.height - 1)
    }

    /// Bez Accessibility: Dock dole uprostřed, šířka podle velikosti ikon a jejich počtu.
    private static func estimateDock(mainScreen: (NSRect, NSRect)?) -> CGRect? {
        guard let (frame, visible) = mainScreen else { return nil }
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        if prefs?.bool(forKey: "autohide") == true { return nil }
        let orientation = prefs?.string(forKey: "orientation") ?? "bottom"
        guard orientation == "bottom" else { return nil }
        let reserved = visible.minY - frame.minY
        guard reserved > 20 else { return nil }
        let tile = CGFloat(prefs?.double(forKey: "tilesize") ?? 48).clamped(16, 128)
        let apps = (prefs?.array(forKey: "persistent-apps") ?? []).count
        let others = (prefs?.array(forKey: "persistent-others") ?? []).count
        let persistentIDs = Set((prefs?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []).compactMap {
            (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String)
        })
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !persistentIDs.contains($0.bundleIdentifier ?? "")
        }.count
        let count = apps + others + 2 + running   // + Finder + Koš
        let width = min(frame.width - 8, CGFloat(count) * tile * 1.08 + 24)
        let height = tile + 14
        let y = frame.height - reserved + max(0, (reserved - height) / 2)
        return CGRect(x: (frame.width - width) / 2, y: y, width: width, height: height)
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(hi, Swift.max(lo, self)) }
}

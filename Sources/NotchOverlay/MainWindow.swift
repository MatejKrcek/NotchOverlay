import AppKit
import ServiceManagement

/// Nastavení appky ve stylu Nastavení systému: vlevo sekce, vpravo skupiny řádků
/// (popisek + krátké vysvětlení vlevo, ovladač vpravo). Otevře se kliknutím na appku
/// ve Finderu/Docku (reopen) nebo při ručním spuštění. Obsah se staví v kódu a přestaví
/// se při každé změně stavu (kvóty, účty, resize) — vybraná sekce i scroll to přežijí.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    var isOverlayOn: (() -> Bool)?
    var setOverlayOn: ((Bool) -> Void)?
    var onSignIn: (() -> Void)?
    var onSignOutClaude: (() -> Void)?
    var onSizeChange: (() -> Void)?
    /// Stav přihlášení ke Claude ("signed in" / "not signed in" / "checking…").
    var claudeStatus: (() -> String)?
    /// Kvóty účtu, na kterém je Claude Code (běžný fetcher) — pro účet mimo rotaci.
    var currentQuota: (() -> QuotaStatus?)?

    /// Sekce v levém panelu.
    enum Pane: String, CaseIterable {
        case general, island, accounts, usage, weather

        var title: String {
            switch self {
            case .general: return "General"
            case .island: return "Island"
            case .accounts: return "Accounts"
            case .usage: return "Usage"
            case .weather: return "Weather"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .island: return "capsule.fill"
            case .accounts: return "person.crop.circle.fill"
            case .usage: return "chart.bar.fill"
            case .weather: return "cloud.snow.fill"
            }
        }
        var color: NSColor {
            switch self {
            case .general: return .systemGray
            case .island: return .systemIndigo
            case .accounts: return AccountBadge.tint
            case .usage: return .systemGreen
            case .weather: return .systemTeal
            }
        }
    }

    /// Vybraná sekce — pamatuje si ji i přes zavření okna a restart appky.
    private var pane: Pane {
        get { Pane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "settingsPane") }
    }

    private var window: NSWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private var scrollView: NSScrollView?
    private var builtPane: Pane?

    // Ovladače aktuální sekce (ostatní sekce = nil).
    private var overlaySwitch: NSSwitch?
    private var soundsSwitch: NSSwitch?
    private var launchSwitch: NSSwitch?
    private var sizeSlider: NSSlider?
    private var panelSlider: NSSlider?
    private var quotaSwitch: NSSwitch?
    private var menuBarSwitch: NSSwitch?
    private var allAccountsSwitch: NSSwitch?
    private var spend24: NSTextField?
    private var spend7: NSTextField?
    private var spend31: NSTextField?
    private var spendYear: NSTextField?
    private let spendStats = SpendStats()
    private var spendCache: SpendSummary?

    private static let defaultSize = NSSize(width: 780, height: 600)
    private static let minSize = NSSize(width: 700, height: 480)
    private let sidebarWidth: CGFloat = 200

    func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "NotchOverlay"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = Self.minSize
            w.delegate = self
            // Nový název autosave: starý rámeček (3 sloupce, 980×600+) k tomuhle rozvržení nesedí.
            if !w.setFrameUsingName("NotchOverlaySettingsV2") { w.center() }
            w.setFrameAutosaveName("NotchOverlaySettingsV2")
            window = w
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        AccountRotation.shared.refreshIfStale()
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if pane == .usage { loadSpend() }
    }

    func windowDidResize(_ notification: Notification) { rebuild() }

    /// Stav účtu se změnil mimo okno (kvóty, login) — překreslit, pokud je otevřená sekce
    /// Accounts. Jiné sekce účty neukazují a přestavba by zavřela popup nebo přerušila
    /// tažení slideru (přichází po každém pollu, cca 5 min).
    func accountsChanged() {
        guard pane == .accounts else { return }
        refresh()
    }

    /// Překreslí obsah okna (stavy účtů) bez přecentrování.
    private func refresh() {
        guard let window, window.isVisible else { return }
        rebuild()
        if pane == .usage { loadSpend() }   // sken všech přepisů — jen když je spend vidět
    }

    private func select(_ p: Pane) {
        guard p != pane else { return }
        pane = p
        rebuild()
        if p == .usage { loadSpend() }
    }

    // MARK: - Stavba okna

    private func rebuild() {
        guard let window, let frameView = window.contentView else { return }
        let size = frameView.bounds.size
        let titlebar = max(28, window.frame.height - window.contentLayoutRect.height)
        let keepScroll = builtPane == pane ? scrollView?.contentView.bounds.origin : nil

        for case let s? in [overlaySwitch, soundsSwitch, launchSwitch, quotaSwitch, menuBarSwitch,
                            allAccountsSwitch] as [NSSwitch?] {
            s.target = nil
        }
        overlaySwitch = nil; soundsSwitch = nil; launchSwitch = nil; sizeSlider = nil; panelSlider = nil
        quotaSwitch = nil; menuBarSwitch = nil; allAccountsSwitch = nil
        spend24 = nil; spend7 = nil; spend31 = nil; spendYear = nil

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(buildSidebar(height: size.height))

        let contentW = size.width - sidebarWidth
        let scroll = NSScrollView(frame: NSRect(x: sidebarWidth, y: 0, width: contentW, height: size.height - titlebar))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let form = SettingsForm(width: contentW)
        switch pane {
        case .general: buildGeneral(form)
        case .island: buildIsland(form)
        case .accounts: buildAccounts(form)
        case .usage: buildUsage(form)
        case .weather: buildWeather(form)
        }
        scroll.documentView = form.finish(minHeight: scroll.contentSize.height)
        root.addSubview(scroll)

        window.contentView = root
        scrollView = scroll
        builtPane = pane
        if let keepScroll {
            scroll.contentView.scroll(to: keepScroll)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        applyControlStates()
        if let s = spendCache { applySpend(s) }
    }

    private func buildSidebar(height: CGFloat) -> NSView {
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: height))
        bar.material = .sidebar
        bar.blendingMode = .behindWindow
        bar.state = .followsWindowActiveState

        var y = height - 52   // pod semafory okna
        for p in Pane.allCases {
            y -= 30
            let item = SidebarItem(frame: NSRect(x: 10, y: y, width: sidebarWidth - 20, height: 28),
                                   title: p.title, symbol: p.symbol, color: p.color, selected: p == pane)
            item.onClick = { [weak self] in self?.select(p) }
            bar.addSubview(item)
            y -= 2
        }

        // Dole: identita appky
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let icon = NSImageView(frame: NSRect(x: 16, y: 16, width: 28, height: 28))
        icon.image = NSApp.applicationIconImage
        bar.addSubview(icon)
        let name = NSTextField(labelWithString: "NotchOverlay")
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.frame = NSRect(x: 50, y: 29, width: sidebarWidth - 60, height: 15)
        bar.addSubview(name)
        let ver = NSTextField(labelWithString: version.map { "Version \($0)" } ?? "")
        ver.font = .systemFont(ofSize: 10.5)
        ver.textColor = .secondaryLabelColor
        ver.frame = NSRect(x: 50, y: 14, width: sidebarWidth - 60, height: 14)
        bar.addSubview(ver)

        let line = NSBox(frame: NSRect(x: sidebarWidth - 1, y: 0, width: 1, height: height))
        line.boxType = .separator
        bar.addSubview(line)
        return bar
    }

    // MARK: - Sekce

    private func buildGeneral(_ f: SettingsForm) {
        f.title("General", subtitle: "Dynamic Island for AI coding agents.")

        f.group("Overlay")
        overlaySwitch = f.switchRow("Island in the notch",
                                    detail: "Shows your agents around the notch. Hover it to open the panel.",
                                    target: self, action: #selector(toggleOverlay(_:)))
        soundsSwitch = f.switchRow("Sounds", detail: "8-bit sounds when an agent finishes or needs you.",
                                   target: self, action: #selector(toggleSounds(_:)))
        f.endGroup()

        f.group("Menu bar")
        menuBarSwitch = f.switchRow("5h session in menu bar",
                                    detail: "Usage of the account Claude Code uses now, next to the clock.",
                                    target: self, action: #selector(toggleMenuBar(_:)))
        f.row("Style", detail: "Choosing a style also turns the item on.",
              control: f.popup(items: [("Usage %", true), ("Reset time", true)],
                               selected: ["pct", "reset"].firstIndex(of: Display.menuBarFiveHourStyle) ?? 0,
                               target: self, action: #selector(menuBarStyleChanged(_:))))
        f.endGroup()

        f.group("Startup")
        let launch = LaunchAtLogin.state
        let launchDetail: String
        if !LaunchAtLogin.canManage {
            launchDetail = "Move NotchOverlay to the Applications folder and open it from there first."
        } else if launch == .blockedBySystem {
            launchDetail = "Turned off in System Settings → General → Login Items. Switch on to open it there."
        } else {
            launchDetail = "Opens NotchOverlay in the background when you log in to your Mac."
        }
        let launchSwitch = f.switchRow("Open at login", detail: launchDetail,
                                       target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchSwitch.isEnabled = LaunchAtLogin.canManage
        launchSwitch.state = launch == .on ? .on : .off
        self.launchSwitch = launchSwitch
        let quit = f.button("Quit", target: self, action: #selector(quit(_:)))
        quit.hasDestructiveAction = true
        f.row("Quit NotchOverlay",
              detail: launch == .on
                ? "Stops the app until your next login or until you open it again."
                : "Stops the app until you open it again.",
              control: quit)
        f.endGroup()
    }

    private func buildIsland(_ f: SettingsForm) {
        f.title("Island", subtitle: "What the island shows and how big it is.")

        f.group("Size")
        let size = f.slider(min: 0.7, max: 1.5, target: self, action: #selector(sizeChanged(_:)),
                            reset: #selector(resetSize(_:)))
        sizeSlider = size.slider
        f.row("Island size", detail: "Width of the island next to the notch.", control: size.view)
        let panel = f.slider(min: 0.8, max: 1.6, target: self, action: #selector(panelSizeChanged(_:)),
                             reset: #selector(resetPanelSize(_:)))
        panelSlider = panel.slider
        f.row("Panel size", detail: "The panel that opens when you hover the island.", control: panel.view)
        f.endGroup()

        f.group("Next to the notch")
        quotaSwitch = f.switchRow("Quota in the bar", detail: "5-hour usage on the right side of the notch.",
                                  target: self, action: #selector(toggleQuota(_:)))
        f.endGroup()

        f.group("Hover panel")
        f.row("Second line", detail: "An extra line under the quota header.",
              control: f.popup(items: [("None", true), ("Codex", true), ("Fable 5", true),
                                       ("Gemini (soon)", false), ("Account rotation", true)],
                               selected: ["none", "codex", "fable", "gemini", "rotation"]
                                   .firstIndex(of: Display.headerSecondLine) ?? 0,
                               target: self, action: #selector(secondLineChanged(_:))))
        f.row("Per session", detail: "What each agent row shows after the model.",
              control: f.popup(items: [("Off", true), ("Tokens", true), ("Spend", true), ("Tokens + spend", true)],
                               selected: Self.perSessionIndex(),
                               target: self, action: #selector(perSessionChanged(_:))))
        f.endGroup()
        f.note("Claude accounts under the agents: see Accounts → Show all accounts.")
    }

    private func buildAccounts(_ f: SettingsForm) {
        f.title("Accounts", subtitle: "Claude accounts and the other agents NotchOverlay watches.")

        // Claude účty s využitím aktuálního 5h okna; ten, ze kterého se čerpá, je podbarvený.
        f.group("Claude accounts")
        let rows = AccountRotation.shared.usageRows(current: currentQuota?())
        if rows.isEmpty {
            f.row("No Claude account found", detail: "Log in to Claude Code with /login.")
        }
        for r in rows {
            let detail = r.active
                ? "In use now. Shown in the menu bar and next to the notch."
                : "Saved for rotation."
            f.row(r.label, detail: detail,
                  icon: AccountBadge.image(size: 22, active: r.active),
                  control: SettingsForm.usageView(r), bold: r.active, pill: r.active,
                  highlighted: r.active, tooltip: r.tooltip)
        }
        allAccountsSwitch = f.switchRow(
            "Show all accounts",
            detail: "Off: only the account Claude Code uses now. On: every account added in Rotation, with its 5-hour usage — here and in the island.",
            target: self, action: #selector(toggleAllAccounts(_:)))
        f.endGroup()

        f.group("Rotation")
        let count = RotationPrefs.accounts.count
        let state = count == 0 ? "Off · no accounts added yet."
            : "\(RotationPrefs.enabled ? "On" : "Off") · \(count) account\(count == 1 ? "" : "s")."
        f.row("Account rotation",
              detail: "\(state) When an account runs out, Claude Code moves to the next one, then to Codex. Switch accounts with /login, never /logout.",
              control: f.button("Set up…", target: self, action: #selector(openRotation(_:))))
        f.endGroup()

        f.group("Usage data")
        let claudeSt = claudeStatus?() ?? "checking…"
        let claudeIn = claudeSt.hasPrefix("signed in")
        let claudeExpired = claudeSt.contains("expired")
        f.row("Claude usage",
              detail: claudeExpired
                ? "Claude Code token expired. NotchOverlay can't refresh it without logging Claude Code out. Sign in here and NotchOverlay keeps its own token fresh."
                : claudeIn ? "Signed in. Usage comes from your Claude login." : claudeSt.capitalizedFirst,
              control: f.button(claudeIn ? "Sign out" : "Sign in…", target: self,
                                action: claudeIn ? #selector(signOutClaude(_:)) : #selector(signIn(_:))),
              detailColor: claudeExpired ? .systemOrange : claudeIn ? .systemGreen : nil)
        f.endGroup()

        f.group("Other agents")
        let codex = Providers.codex()
        f.row("Codex CLI", detail: codex.label.capitalizedFirst,
              control: !codex.installed ? nil
                : f.button(codex.signedIn ? "Sign out" : "Sign in…", target: self,
                           action: codex.signedIn ? #selector(signOutCodex(_:)) : #selector(signInCodex(_:))),
              detailColor: codex.signedIn ? .systemGreen : nil)
        let gemini = Providers.gemini()
        f.row("Gemini CLI", detail: gemini.label.capitalizedFirst,
              control: !gemini.installed ? nil
                : f.button(gemini.signedIn ? "Sign out" : "Sign in…", target: self,
                           action: gemini.signedIn ? #selector(signOutGemini(_:)) : #selector(signInGemini(_:))),
              detailColor: gemini.signedIn ? .systemGreen : nil)
        f.endGroup()
    }

    private func buildUsage(_ f: SettingsForm) {
        f.title("Usage", subtitle: "Tokens and estimated cost of your agents.")
        f.group("Estimated spend")
        spend24 = f.valueRow("Last 24 hours")
        spend7 = f.valueRow("Last 7 days")
        spend31 = f.valueRow("Last 31 days")
        spendYear = f.valueRow("This year")
        f.endGroup()
        f.note("Estimated from local transcripts on this Mac.")
    }

    private func buildWeather(_ f: SettingsForm) {
        let mode = WeatherPrefs.mode
        let rain = mode == .rain
        f.title("Weather", subtitle: "Snow, leaves, rain or petals falling over your desktop.")

        f.group("Weather")
        let on = f.switchRow("Weather on desktop", detail: nil, target: self, action: #selector(toggleWeather(_:)))
        on.state = WeatherPrefs.enabled ? .on : .off
        f.row("Mode", control: f.popup(items: WeatherMode.allCases.map { ($0.title, true) },
                                       selected: WeatherMode.allCases.firstIndex(of: mode) ?? 0,
                                       target: self, action: #selector(weatherModeChanged(_:))))
        let halloween = f.switchRow("Halloween",
                                    detail: "Jack-o'-lanterns and ghosts in the snow. On by itself from October 30 until dawn on November 1.",
                                    target: self, action: #selector(toggleHalloween(_:)))
        halloween.state = (WeatherPrefs.halloween || (WeatherPrefs.isHalloweenSeason() && mode == .snow)) ? .on : .off
        halloween.isEnabled = mode == .snow && !WeatherPrefs.isHalloweenSeason()
        f.row("Intensity", control: f.popup(items: WeatherIntensity.allCases.map { ($0.title, true) },
                                            selected: WeatherIntensity.allCases.firstIndex(of: WeatherPrefs.intensity) ?? 1,
                                            target: self, action: #selector(weatherIntensityChanged(_:))))
        let opacity = f.slider(min: 0.2, max: 1, target: self, action: #selector(weatherOpacityChanged(_:)),
                               reset: #selector(resetWeatherOpacity(_:)))
        opacity.slider.doubleValue = WeatherPrefs.opacity
        f.row("Opacity", control: opacity.view)
        f.endGroup()

        f.group("Where it settles")
        f.row("Accumulate on", detail: rain ? "Rain doesn't pile up. It splashes at the bottom." : "Ground, Dock, window tops and widgets.",
              control: accumulateControl(rain: rain))
        let melt = f.switchRow(mode.meltTitle, detail: nil, target: self, action: #selector(toggleWeatherMelt(_:)))
        melt.state = WeatherPrefs.melt ? .on : .off
        melt.isEnabled = !rain
        let clear = f.button(mode.clearTitle, target: self, action: #selector(clearWeather(_:)))
        clear.isEnabled = !rain
        f.row("Clear the desktop", detail: "Removes everything that has piled up.", control: clear)
        f.endGroup()

        f.group("Advanced")
        let options: [(String, Bool, Selector, String)] = [
            ("Deep interaction", WeatherPrefs.deepInteraction, #selector(toggleDeepInteraction(_:)),
             "Snow also settles on a selection dragged across the desktop."),
            ("Behind windows", WeatherPrefs.behindWindows, #selector(toggleBehindWindows(_:)),
             "Draw the weather under your windows, on the desktop only."),
            ("Show over full screen", WeatherPrefs.overFullScreen, #selector(toggleOverFullScreen(_:)),
             "Keep it falling over full-screen apps."),
            ("Show in screenshots", WeatherPrefs.showInScreenshots, #selector(toggleShowInScreenshots(_:)),
             "Off: screenshots and screen sharing show your desktop without it."),
            ("Max performance", WeatherPrefs.maxPerformance, #selector(toggleMaxPerformance(_:)),
             "Full frame rate and resolution. Off: 20–30 fps at half resolution, which uses far less CPU and memory."),
        ]
        for (title, isOn, action, detail) in options {
            let s = f.switchRow(title, detail: detail, target: self, action: action)
            s.state = isOn ? .on : .off
        }
        f.endGroup()
    }

    /// Na co se sníh usazuje: zem / Dock / okna / widgety (víc voleb najednou).
    private func accumulateControl(rain: Bool) -> NSView {
        let symbols = ["arrow.down.to.line", "dock.rectangle", "macwindow", "square.grid.2x2"]
        let names = ["Ground", "Dock", "Windows", "Widgets"]
        let seg = NSSegmentedControl()
        seg.segmentCount = 4
        seg.trackingMode = .selectAny
        for i in 0..<4 {
            if let img = NSImage(systemSymbolName: symbols[i], accessibilityDescription: names[i]) {
                seg.setImage(img, forSegment: i)
            } else {
                seg.setLabel(names[i], forSegment: i)
            }
            seg.setToolTip(names[i], forSegment: i)
            seg.setWidth(34, forSegment: i)
        }
        seg.setSelected(WeatherPrefs.onGround || rain, forSegment: 0)
        seg.setSelected(WeatherPrefs.onDock, forSegment: 1)
        seg.setSelected(WeatherPrefs.onWindows, forSegment: 2)
        seg.setSelected(WeatherPrefs.onWidgets, forSegment: 3)
        // déšť se nehromadí — dole šplíchá vždycky
        seg.setEnabled(!rain, forSegment: 0)
        seg.target = self
        seg.action = #selector(weatherAccumulateChanged(_:))
        seg.sizeToFit()
        return seg
    }

    /// Index v popupu „Per session": 0 off, 1 tokens, 2 spend, 3 obojí.
    private static func perSessionIndex() -> Int {
        (Display.showSessionTokens ? 1 : 0) + (Display.showSessionSpend ? 2 : 0)
    }

    // MARK: - Spend

    /// Načte spend: čerstvou cache použije hned, jinak spustí přepočet na pozadí.
    private func loadSpend() {
        if let s = spendCache, let at = s.computedAt, Date().timeIntervalSince(at) < 60 {
            applySpend(s)
            return
        }
        spendStats.compute { [weak self] summary in
            self?.spendCache = summary
            self?.applySpend(summary)
        }
    }

    private func applySpend(_ s: SpendSummary) {
        func fmt(_ w: SpendWindow) -> String { "\(shortTokens(w.tokens)) · \(shortUSD(w.costUSD))" }
        spend24?.stringValue = fmt(s.last24h)
        spend7?.stringValue = fmt(s.last7d)
        spend31?.stringValue = fmt(s.last31d)
        spendYear?.stringValue = fmt(s.thisYear)
    }

    /// Nastaví ovládací prvky podle uložených hodnot (po každé stavbě sekce).
    private func applyControlStates() {
        overlaySwitch?.state = (isOverlayOn?() ?? true) ? .on : .off
        soundsSwitch?.state = Sounds.shared.enabled ? .on : .off
        let scale = UserDefaults.standard.double(forKey: "islandScale")
        sizeSlider?.doubleValue = scale == 0 ? 1 : scale
        let panel = UserDefaults.standard.double(forKey: "panelScale")
        panelSlider?.doubleValue = panel == 0 ? 1 : panel
        quotaSwitch?.state = Display.showQuotaInBar ? .on : .off
        menuBarSwitch?.state = Display.menuBarFiveHour != "off" ? .on : .off
        allAccountsSwitch?.state = Display.showAllAccounts ? .on : .off
    }

    // MARK: - Akce: počasí

    @objc private func toggleWeather(_ sender: NSSwitch) {
        WeatherPrefs.enabled = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func weatherModeChanged(_ sender: NSPopUpButton) {
        WeatherPrefs.mode = WeatherMode.allCases[max(0, sender.indexOfSelectedItem)]
        WeatherController.shared.prefsChanged()
        rebuild()  // popisky Melt/Clear a dostupnost voleb se mění s módem
    }

    @objc private func toggleHalloween(_ sender: NSSwitch) {
        WeatherPrefs.halloween = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func weatherIntensityChanged(_ sender: NSPopUpButton) {
        WeatherPrefs.intensity = WeatherIntensity.allCases[max(0, sender.indexOfSelectedItem)]
        WeatherController.shared.prefsChanged()
    }

    @objc private func weatherOpacityChanged(_ sender: NSSlider) {
        WeatherPrefs.opacity = sender.doubleValue
        WeatherController.shared.prefsChanged()
    }

    @objc private func resetWeatherOpacity(_ sender: NSButton) {
        UserDefaults.standard.removeObject(forKey: "weatherOpacity")
        WeatherController.shared.prefsChanged()
        rebuild()
    }

    @objc private func weatherAccumulateChanged(_ sender: NSSegmentedControl) {
        if WeatherPrefs.mode != .rain { WeatherPrefs.onGround = sender.isSelected(forSegment: 0) }
        WeatherPrefs.onDock = sender.isSelected(forSegment: 1)
        WeatherPrefs.onWindows = sender.isSelected(forSegment: 2)
        WeatherPrefs.onWidgets = sender.isSelected(forSegment: 3)
        WeatherController.shared.prefsChanged()
    }

    @objc private func toggleWeatherMelt(_ sender: NSSwitch) {
        WeatherPrefs.melt = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func clearWeather(_ sender: NSButton) {
        WeatherController.shared.clear()
    }

    @objc private func toggleDeepInteraction(_ sender: NSSwitch) {
        WeatherPrefs.deepInteraction = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func toggleBehindWindows(_ sender: NSSwitch) {
        WeatherPrefs.behindWindows = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func toggleOverFullScreen(_ sender: NSSwitch) {
        WeatherPrefs.overFullScreen = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func toggleShowInScreenshots(_ sender: NSSwitch) {
        WeatherPrefs.showInScreenshots = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    @objc private func toggleMaxPerformance(_ sender: NSSwitch) {
        WeatherPrefs.maxPerformance = sender.state == .on
        WeatherController.shared.prefsChanged()
    }

    // MARK: - Akce: overlay, zobrazení, účty

    @objc private func toggleOverlay(_ sender: NSSwitch) {
        setOverlayOn?(sender.state == .on)
    }

    @objc private func toggleSounds(_ sender: NSSwitch) {
        Sounds.shared.enabled = sender.state == .on
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        let on = sender.state == .on
        // Agent existuje, ale uživatel ho vypnul v Nastavení systému — povolit jde jen tam.
        if on && LaunchAtLogin.state == .blockedBySystem {
            SMAppService.openSystemSettingsLoginItems()
            sender.state = .off
            return
        }
        do {
            try LaunchAtLogin.setEnabled(on)
        } catch {
            sender.state = on ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()   // popis řádku Quit závisí na stavu
    }

    @objc private func perSessionChanged(_ sender: NSPopUpButton) {
        let i = max(0, sender.indexOfSelectedItem)
        Display.showSessionTokens = i == 1 || i == 3
        Display.showSessionSpend = i == 2 || i == 3
        onSizeChange?()
    }

    @objc private func panelSizeChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "panelScale")
        onSizeChange?()
    }

    @objc private func resetPanelSize(_ sender: NSButton) {
        UserDefaults.standard.removeObject(forKey: "panelScale")
        panelSlider?.doubleValue = 1
        onSizeChange?()
    }

    @objc private func toggleQuota(_ sender: NSSwitch) {
        Display.showQuotaInBar = sender.state == .on
        onSizeChange?()
    }

    @objc private func secondLineChanged(_ sender: NSPopUpButton) {
        Display.headerSecondLine = ["none", "codex", "fable", "gemini", "rotation"][max(0, sender.indexOfSelectedItem)]
        onSizeChange?()
    }

    @objc private func toggleMenuBar(_ sender: NSSwitch) {
        Display.menuBarFiveHour = sender.state == .on ? Display.menuBarFiveHourStyle : "off"
        MenuBarController.shared.applyMode()
    }

    /// Výběr stylu položku rovnou zapne — vybírat styl vypnuté položky nedává smysl.
    @objc private func menuBarStyleChanged(_ sender: NSPopUpButton) {
        let style = ["pct", "reset"][max(0, sender.indexOfSelectedItem)]
        Display.menuBarFiveHourStyle = style
        Display.menuBarFiveHour = style
        menuBarSwitch?.state = .on
        MenuBarController.shared.applyMode()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "islandScale")
        onSizeChange?()
    }

    @objc private func resetSize(_ sender: NSButton) {
        UserDefaults.standard.removeObject(forKey: "islandScale")
        sizeSlider?.doubleValue = 1
        onSizeChange?()
    }

    @objc private func toggleAllAccounts(_ sender: NSSwitch) {
        Display.showAllAccounts = sender.state == .on
        onSizeChange?()   // island: jiný počet řádků účtů → nová výška
        refresh()
    }

    @objc private func signIn(_ sender: NSButton) {
        onSignIn?()
    }

    @objc private func openRotation(_ sender: NSButton) {
        RotationWindowController.shared.present()
    }

    @objc private func signInCodex(_ sender: NSButton) {
        if let cmd = Providers.codex().loginCommand { Providers.openLogin(command: cmd) }
    }

    @objc private func signInGemini(_ sender: NSButton) {
        if let cmd = Providers.gemini().loginCommand { Providers.openLogin(command: cmd) }
    }

    @objc private func signOutClaude(_ sender: NSButton) {
        onSignOutClaude?()
        refresh()
    }

    @objc private func signOutCodex(_ sender: NSButton) {
        Providers.signOutCodex()
        refresh()
    }

    @objc private func signOutGemini(_ sender: NSButton) {
        Providers.signOutGemini()
        refresh()
    }

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

private extension String {
    /// „not signed in" → „Not signed in" (stav jako věta pod popiskem).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Postranní panel

/// Položka sekce: barevná ikona + název; vybraná má akcentní podklad.
private final class SidebarItem: NSView {
    var onClick: (() -> Void)?

    init(frame: NSRect, title: String, symbol: String, color: NSColor, selected: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        if selected { layer?.backgroundColor = NSColor.controlAccentColor.cgColor }

        let tile = NSView(frame: NSRect(x: 6, y: (frame.height - 20) / 2, width: 20, height: 20))
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 5
        tile.layer?.backgroundColor = color.cgColor
        let img = NSImageView(frame: tile.bounds.insetBy(dx: 3, dy: 3))
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        img.contentTintColor = .white
        tile.addSubview(img)
        addSubview(tile)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        label.textColor = selected ? .white : .labelColor
        label.frame = NSRect(x: 34, y: (frame.height - 17) / 2, width: frame.width - 40, height: 17)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Formulář: skupiny řádků jako v Nastavení systému

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Zaoblená skupina řádků; barvy se přepočítají při přepnutí světlý/tmavý vzhled.
private final class CardView: FlippedView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.white).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
}

/// Staví sekci shora dolů: nadpis, skupiny (karty) s řádky, poznámky.
private final class SettingsForm {
    private let doc = FlippedView()
    private let x: CGFloat = 24
    private let w: CGFloat
    private var y: CGFloat = 12
    private var card: CardView?
    private var cardH: CGFloat = 0
    private let pad: CGFloat = 14

    init(width: CGFloat) {
        w = max(360, width - 48)
    }

    func finish(minHeight: CGFloat) -> NSView {
        doc.frame = NSRect(x: 0, y: 0, width: w + 48, height: max(minHeight, y + 24))
        return doc
    }

    func title(_ text: String, subtitle: String? = nil) {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 20, weight: .bold)
        t.frame = NSRect(x: x, y: y, width: w, height: 26)
        doc.addSubview(t)
        y += 28
        if let subtitle {
            let s = NSTextField(labelWithString: subtitle)
            s.font = .systemFont(ofSize: 12)
            s.textColor = .secondaryLabelColor
            s.frame = NSRect(x: x, y: y, width: w, height: 16)
            doc.addSubview(s)
            y += 18
        }
        y += 14
    }

    func group(_ title: String? = nil) {
        if let title {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: x + 4, y: y, width: w, height: 16)
            doc.addSubview(l)
            y += 21
        }
        let c = CardView(frame: NSRect(x: x, y: y, width: w, height: 0))
        c.wantsLayer = true
        c.layer?.cornerRadius = 9
        c.layer?.borderWidth = 1
        card = c
        cardH = 0
        doc.addSubview(c)
    }

    func endGroup() {
        guard let card else { return }
        card.frame.size.height = cardH
        y += cardH + 22
        self.card = nil
    }

    func note(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        let h = Self.height(of: l, width: w - 8)
        l.frame = NSRect(x: x + 4, y: y - 12, width: w - 8, height: h)
        doc.addSubview(l)
        y += h + 10
    }

    /// Řádek: [ikona] název + vysvětlení vlevo, ovladač vpravo, oddělovač nad ním.
    @discardableResult
    func row(_ title: String, detail: String? = nil, icon: NSImage? = nil, control: NSView? = nil,
             bold: Bool = false, pill: Bool = false, highlighted: Bool = false,
             detailColor: NSColor? = nil, tooltip: String? = nil) -> NSView {
        guard let card else { return NSView() }
        let cw = w
        let controlSize = control.map { $0.frame.size == .zero ? $0.fittingSize : $0.frame.size } ?? .zero
        let iconW: CGFloat = icon == nil ? 0 : 32
        let textX = pad + iconW
        let textW = cw - textX - pad - (control == nil ? 0 : controlSize.width + 14)

        let titleL = NSTextField(labelWithString: title)
        titleL.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        titleL.lineBreakMode = .byTruncatingTail
        titleL.toolTip = tooltip

        var detailL: NSTextField?
        var detailH: CGFloat = 0
        if let detail, !detail.isEmpty {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = detailColor ?? .secondaryLabelColor
            d.toolTip = tooltip
            detailH = Self.height(of: d, width: textW)
            detailL = d
        }
        let rowH = max(44, 10 + 17 + (detailL == nil ? 0 : 2 + detailH) + 10, controlSize.height + 20)
        let row = FlippedView(frame: NSRect(x: 0, y: cardH, width: cw, height: rowH))

        if highlighted {
            let bg = NSView(frame: row.bounds.insetBy(dx: 4, dy: 3))
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 7
            bg.layer?.backgroundColor = AccountBadge.tint.withAlphaComponent(0.12).cgColor
            bg.layer?.borderWidth = 1
            bg.layer?.borderColor = AccountBadge.tint.withAlphaComponent(0.4).cgColor
            row.addSubview(bg)
        }
        if cardH > 0 {
            let sep = NSBox(frame: NSRect(x: pad, y: 0, width: cw - 2 * pad, height: 1))
            sep.boxType = .separator
            row.addSubview(sep)
        }
        if let icon {
            let iv = NSImageView(frame: NSRect(x: pad, y: (rowH - 22) / 2, width: 22, height: 22))
            iv.image = icon
            row.addSubview(iv)
        }
        let titleY = detailL == nil ? (rowH - 17) / 2 : 10
        if pill {
            let p = AccountBadge.inUsePill(scale: 1.15)
            let natural = (title as NSString).size(withAttributes: [.font: titleL.font as Any]).width
            let tw = min(ceil(natural) + 6, textW - p.frame.width - 8)
            titleL.frame = NSRect(x: textX, y: titleY, width: max(40, tw), height: 17)
            p.frame.origin = NSPoint(x: titleL.frame.maxX + 7, y: titleY + (17 - p.frame.height) / 2)
            row.addSubview(p)
        } else {
            titleL.frame = NSRect(x: textX, y: titleY, width: textW, height: 17)
        }
        row.addSubview(titleL)
        if let d = detailL {
            d.frame = NSRect(x: textX, y: 10 + 17 + 2, width: textW, height: detailH)
            row.addSubview(d)
        }
        if let control {
            control.frame = NSRect(x: cw - pad - controlSize.width, y: (rowH - controlSize.height) / 2,
                                   width: controlSize.width, height: controlSize.height)
            row.addSubview(control)
        }
        card.addSubview(row)
        cardH += rowH
        return row
    }

    // MARK: Ovladače

    func switchRow(_ title: String, detail: String?, target: AnyObject, action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        s.frame.size = s.fittingSize
        row(title, detail: detail, control: s)
        return s
    }

    func popup(items: [(title: String, enabled: Bool)], selected: Int, target: AnyObject,
               action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 25))
        for item in items {
            p.addItem(withTitle: item.title)
            p.lastItem?.isEnabled = item.enabled
        }
        p.autoenablesItems = false
        p.selectItem(at: selected)
        p.target = target
        p.action = action
        return p
    }

    func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.sizeToFit()
        b.frame.size.width = max(84, b.frame.width + 8)
        return b
    }

    /// Slider + Reset vedle sebe.
    func slider(min: Double, max: Double, target: AnyObject, action: Selector,
                reset: Selector) -> (view: NSView, slider: NSSlider) {
        let box = FlippedView(frame: NSRect(x: 0, y: 0, width: 236, height: 24))
        let s = NSSlider(value: 1, minValue: min, maxValue: max, target: target, action: action)
        s.isContinuous = true
        s.frame = NSRect(x: 0, y: 1, width: 160, height: 22)
        box.addSubview(s)
        let b = NSButton(title: "Reset", target: target, action: reset)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.frame = NSRect(x: 168, y: 1, width: 68, height: 22)
        box.addSubview(b)
        return (box, s)
    }

    /// Řádek s hodnotou vpravo (spend); vrací pole hodnoty kvůli pozdější aktualizaci.
    func valueRow(_ title: String) -> NSTextField {
        let v = NSTextField(labelWithString: "…")
        v.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        v.textColor = .secondaryLabelColor
        v.alignment = .right
        v.frame.size = NSSize(width: 200, height: 17)
        row(title, control: v)
        return v
    }

    /// Limity účtu pod sebou: 5h, týden, Fable (a Opus, když ho API vrací) —
    /// název, ukazatel, procento, čas do resetu. Nad prahem rotace oranžově.
    static func usageView(_ r: AccountRotation.UsageRow) -> NSView {
        guard let q = r.quota else {
            let l = NSTextField(labelWithString: r.text)
            l.font = .systemFont(ofSize: 12)
            l.textColor = r.warning ? .systemOrange : .secondaryLabelColor
            l.alignment = .right
            l.toolTip = r.tooltip
            l.frame.size = NSSize(width: 200, height: 16)
            return l
        }
        let windows: [(String, QuotaWindow?)] = [("5h", q.fiveHour), ("Week", q.sevenDay),
                                                 ("Opus", q.sevenDayOpus), ("Fable", q.sevenDayFable)]
        let lines = windows.compactMap { name, w in w.map { (name, $0) } }
        let lineH: CGFloat = 17
        let nameW: CGFloat = 40, barW: CGFloat = 96, pctW: CGFloat = 38, resetW: CGFloat = 54
        let width = nameW + 6 + barW + 8 + pctW + 8 + resetW
        let box = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(lines.count) * lineH))
        box.toolTip = r.tooltip
        let threshold = RotationPrefs.threshold
        for (i, (name, w)) in lines.enumerated() {
            let y = CGFloat(i) * lineH
            let live = (w.resetsAt ?? .distantFuture) > Date()   // reset už proběhl → okno je nové
            let pct = live ? w.pct : 0
            let hot = pct >= threshold

            let n = NSTextField(labelWithString: name)
            n.font = .systemFont(ofSize: 11, weight: .medium)
            n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: 0, y: y, width: nameW, height: 15)
            box.addSubview(n)

            let track = NSView(frame: NSRect(x: nameW + 6, y: y + 5, width: barW, height: 5))
            track.wantsLayer = true
            track.layer?.cornerRadius = 2.5
            track.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor
            let fill = NSView(frame: NSRect(x: 0, y: 0, width: max(2, barW * CGFloat(min(max(pct, 0), 100)) / 100), height: 5))
            fill.wantsLayer = true
            fill.layer?.cornerRadius = 2.5
            fill.layer?.backgroundColor = (hot ? NSColor.systemOrange
                : r.active ? AccountBadge.tint : NSColor.secondaryLabelColor).cgColor
            track.addSubview(fill)
            box.addSubview(track)

            let p = NSTextField(labelWithString: "\(pct)%")
            p.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: r.active || hot ? .semibold : .regular)
            p.textColor = hot ? .systemOrange : r.active ? .labelColor : .secondaryLabelColor
            p.alignment = .right
            p.frame = NSRect(x: nameW + 6 + barW + 8, y: y, width: pctW, height: 15)
            box.addSubview(p)

            let reset = NSTextField(labelWithString: live ? (w.resetsAt.map { remainingString(until: $0) } ?? "") : "new")
            reset.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            reset.textColor = .tertiaryLabelColor
            reset.alignment = .right
            reset.frame = NSRect(x: width - resetW, y: y, width: resetW, height: 15)
            box.addSubview(reset)
        }
        return box
    }

    static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 14)
    }
}

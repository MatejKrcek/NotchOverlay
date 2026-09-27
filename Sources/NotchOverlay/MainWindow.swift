import AppKit

/// Hlavní okno appky — otevře se kliknutím na appku ve Finderu/Docku
/// (reopen) nebo při ručním spuštění. Overlay on/off, zvuky, velikost,
/// zobrazování (tokeny, kvóta), účty (Claude/Codex/Gemini), quit.
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    var isOverlayOn: (() -> Bool)?
    var setOverlayOn: ((Bool) -> Void)?
    var onSignIn: (() -> Void)?
    var onSignOutClaude: (() -> Void)?
    var onSizeChange: (() -> Void)?
    /// Stav přihlášení ke Claude ("signed in" / "not signed in" / "checking…").
    var claudeStatus: (() -> String)?

    private var window: NSWindow?
    private var overlaySwitch: NSSwitch?
    private var soundsSwitch: NSSwitch?
    private var sizeSlider: NSSlider?
    private var panelSlider: NSSlider?
    private var quotaSwitch: NSSwitch?
    private var menuBarSwitch: NSSwitch?
    private var spend24: NSTextField?
    private var spend7: NSTextField?
    private var spend31: NSTextField?
    private var spendYear: NSTextField?
    private let spendStats = SpendStats()
    private var spendCache: SpendSummary?

    func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 862),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "NotchOverlay"
            w.isReleasedWhenClosed = false
            window = w
        }
        // obsah se staví při každém otevření — stavy účtů se mění mimo appku
        window?.contentView = buildContent()
        overlaySwitch?.state = (isOverlayOn?() ?? true) ? .on : .off
        soundsSwitch?.state = Sounds.shared.enabled ? .on : .off
        applyControlStates()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        loadSpend()
    }

    private func switchRow(_ v: NSView, label: String, y: CGFloat,
                           action: Selector) -> NSSwitch {
        let width = v.frame.width
        let l = NSTextField(labelWithString: label)
        l.frame = NSRect(x: 24, y: y + 4, width: 250, height: 20)
        v.addSubview(l)
        let s = NSSwitch(frame: NSRect(x: width - 24 - 38, y: y, width: 38, height: 24))
        s.target = self
        s.action = action
        v.addSubview(s)
        return s
    }

    private func accountRow(_ v: NSView, name: String, status: String, y: CGFloat,
                            buttonTitle: String?, action: Selector?) {
        let width = v.frame.width
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.frame = NSRect(x: 24, y: y + 3, width: 110, height: 18)
        v.addSubview(l)
        let st = NSTextField(labelWithString: status)
        st.font = .systemFont(ofSize: 11)
        st.textColor = status.hasPrefix("signed in") ? .systemGreen : .secondaryLabelColor
        st.frame = NSRect(x: 138, y: y + 4, width: 130, height: 16)
        v.addSubview(st)
        if let buttonTitle, let action {
            let b = NSButton(title: buttonTitle, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.frame = NSRect(x: width - 24 - 90, y: y, width: 90, height: 24)
            v.addSubview(b)
        }
    }

    /// Řádek se sliderem (měřítko) + tlačítkem Reset. Vrací slider, ať jde nastavit hodnota.
    private func sliderRow(_ v: NSView, label: String, y: CGFloat, min: Double, max: Double,
                           action: Selector, reset: Selector) -> NSSlider {
        let width = v.frame.width
        let l = NSTextField(labelWithString: label)
        l.frame = NSRect(x: 24, y: y + 4, width: 120, height: 20)
        v.addSubview(l)
        let slider = NSSlider(value: 1, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 150, y: y, width: width - 150 - 24 - 66, height: 24)
        v.addSubview(slider)
        let b = NSButton(title: "Reset", target: self, action: reset)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.frame = NSRect(x: width - 24 - 58, y: y, width: 58, height: 22)
        v.addSubview(b)
        return slider
    }

    /// Index v popupu „Per session": 0 off, 1 tokens, 2 spend, 3 obojí.
    private static func perSessionIndex() -> Int {
        (Display.showSessionTokens ? 1 : 0) + (Display.showSessionSpend ? 2 : 0)
    }

    /// Řádek s popup výběrem; disabled položky zůstávají viditelné („soon").
    private func popupRow(_ v: NSView, label: String, y: CGFloat,
                          items: [(title: String, enabled: Bool)],
                          selected: Int, action: Selector) {
        let width = v.frame.width
        let l = NSTextField(labelWithString: label)
        l.frame = NSRect(x: 24, y: y + 4, width: 160, height: 20)
        v.addSubview(l)
        let popup = NSPopUpButton(frame: NSRect(x: width - 24 - 150, y: y, width: 150, height: 26))
        for item in items {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.isEnabled = item.enabled
        }
        popup.autoenablesItems = false
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = action
        v.addSubview(popup)
    }

    /// Řádek spendu: vlevo popisek, vpravo hodnota „<tokeny> · $<cena>".
    /// Vrací value field, ať ho lze async aktualizovat.
    private func spendRow(_ v: NSView, label: String, y: CGFloat) -> NSTextField {
        let width = v.frame.width
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: 24, y: y, width: 140, height: 18)
        v.addSubview(l)
        let val = NSTextField(labelWithString: "…")
        val.font = .systemFont(ofSize: 12, weight: .medium)
        val.alignment = .right
        val.textColor = .secondaryLabelColor
        val.frame = NSRect(x: width - 24 - 220, y: y, width: 220, height: 18)
        v.addSubview(val)
        return val
    }

    private func buildContent() -> NSView {
        let width = 400.0, height = 862.0
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // Kurzor: horní hrana dalšího prvku, klesá dolů. Žádné magic-numbers.
        var y = height - 16

        y -= 64
        let icon = NSImageView(frame: NSRect(x: width / 2 - 32, y: y, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        v.addSubview(icon)
        y -= 8

        y -= 24
        let title = NSTextField(labelWithString: "NotchOverlay")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: y, width: width, height: 24)
        v.addSubview(title)

        y -= 18
        let subtitle = NSTextField(labelWithString: "Dynamic Island for AI coding agents")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: y, width: width, height: 16)
        v.addSubview(subtitle)
        y -= 28

        y -= 24
        overlaySwitch = switchRow(v, label: "Island in the notch", y: y,
                                  action: #selector(toggleOverlay(_:)))
        y -= 36
        soundsSwitch = switchRow(v, label: "Sounds", y: y,
                                 action: #selector(toggleSounds(_:)))
        y -= 36

        sizeSlider = sliderRow(v, label: "Island size", y: y, min: 0.7, max: 1.5,
                               action: #selector(sizeChanged(_:)),
                               reset: #selector(resetSize(_:)))
        y -= 36
        panelSlider = sliderRow(v, label: "Panel size", y: y, min: 0.8, max: 1.6,
                                action: #selector(panelSizeChanged(_:)),
                                reset: #selector(resetPanelSize(_:)))
        y -= 36

        popupRow(v, label: "Per session", y: y,
                 items: [("Off", true), ("Tokens", true), ("Spend", true), ("Tokens + spend", true)],
                 selected: Self.perSessionIndex(), action: #selector(perSessionChanged(_:)))
        y -= 36
        quotaSwitch = switchRow(v, label: "Quota in the bar", y: y,
                                action: #selector(toggleQuota(_:)))
        y -= 38

        popupRow(v, label: "Second line", y: y,
                 items: [("None", true), ("Codex", true), ("Fable 5", true),
                         ("Gemini (soon)", false)],
                 selected: ["none", "codex", "fable", "gemini"].firstIndex(of: Display.headerSecondLine) ?? 0,
                 action: #selector(secondLineChanged(_:)))
        y -= 34

        menuBarSwitch = switchRow(v, label: "5h session in menu bar", y: y,
                                  action: #selector(toggleMenuBar(_:)))
        y -= 36
        popupRow(v, label: "Menu bar style", y: y,
                 items: [("Usage %", true), ("Reset time", true)],
                 selected: ["pct", "reset"].firstIndex(of: Display.menuBarFiveHourStyle) ?? 0,
                 action: #selector(menuBarStyleChanged(_:)))
        y -= 34

        // SPEND
        y -= 14
        let spendHdr = NSTextField(labelWithString: "SPEND")
        spendHdr.font = .systemFont(ofSize: 10, weight: .semibold)
        spendHdr.textColor = .secondaryLabelColor
        spendHdr.frame = NSRect(x: 24, y: y, width: 200, height: 14)
        v.addSubview(spendHdr)
        y -= 28

        spend24 = spendRow(v, label: "Last 24h", y: y);      y -= 28
        spend7 = spendRow(v, label: "Last 7 days", y: y);    y -= 28
        spend31 = spendRow(v, label: "Last 31 days", y: y);  y -= 28
        spendYear = spendRow(v, label: "This year", y: y);   y -= 24

        let spendNote = NSTextField(labelWithString: "Estimate from local transcripts.")
        spendNote.font = .systemFont(ofSize: 11)
        spendNote.textColor = .secondaryLabelColor
        spendNote.frame = NSRect(x: 24, y: y, width: width - 48, height: 14)
        v.addSubview(spendNote)
        y -= 28

        // ACCOUNTS
        let accounts = NSTextField(labelWithString: "ACCOUNTS")
        accounts.font = .systemFont(ofSize: 10, weight: .semibold)
        accounts.textColor = .secondaryLabelColor
        accounts.frame = NSRect(x: 24, y: y, width: 200, height: 14)
        v.addSubview(accounts)
        y -= 30

        let claudeSt = claudeStatus?() ?? "checking…"
        let claudeIn = claudeSt.hasPrefix("signed in")
        accountRow(v, name: "Claude", status: claudeSt, y: y,
                   buttonTitle: claudeIn ? "Sign out" : "Sign in…",
                   action: claudeIn ? #selector(signOutClaude(_:)) : #selector(signIn(_:)))
        y -= 30
        let codex = Providers.codex()
        accountRow(v, name: "Codex CLI", status: codex.label, y: y,
                   buttonTitle: !codex.installed ? nil : (codex.signedIn ? "Sign out" : "Sign in…"),
                   action: !codex.installed ? nil
                         : (codex.signedIn ? #selector(signOutCodex(_:)) : #selector(signInCodex(_:))))
        y -= 30
        let gemini = Providers.gemini()
        accountRow(v, name: "Gemini CLI", status: gemini.label, y: y,
                   buttonTitle: !gemini.installed ? nil : (gemini.signedIn ? "Sign out" : "Sign in…"),
                   action: !gemini.installed ? nil
                         : (gemini.signedIn ? #selector(signOutGemini(_:)) : #selector(signInGemini(_:))))
        y -= 44

        let quit = NSButton(title: "Quit NotchOverlay", target: self, action: #selector(quit(_:)))
        quit.bezelStyle = .rounded
        quit.hasDestructiveAction = true
        quit.frame = NSRect(x: 24, y: y, width: width - 48, height: 32)
        v.addSubview(quit)
        y -= 24

        let note = NSTextField(wrappingLabelWithString:
            "Quit stops the app until your next login (or manual launch).")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 24, y: y - 4, width: width - 48, height: 16)
        v.addSubview(note)

        return v
    }

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

    @objc private func toggleOverlay(_ sender: NSSwitch) {
        setOverlayOn?(sender.state == .on)
    }

    @objc private func toggleSounds(_ sender: NSSwitch) {
        Sounds.shared.enabled = sender.state == .on
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
        Display.headerSecondLine = ["none", "codex", "fable", "gemini"][max(0, sender.indexOfSelectedItem)]
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

    @objc private func signIn(_ sender: NSButton) {
        onSignIn?()
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

    /// Překreslí obsah okna (stavy účtů) bez přecentrování.
    private func refresh() {
        guard let window, window.isVisible else { return }
        window.contentView = buildContent()
        applyControlStates()
        loadSpend()
    }

    /// Nastaví ovládací prvky podle uložených hodnot (po každém buildContent).
    private func applyControlStates() {
        overlaySwitch?.state = (isOverlayOn?() ?? true) ? .on : .off
        soundsSwitch?.state = Sounds.shared.enabled ? .on : .off
        let scale = UserDefaults.standard.double(forKey: "islandScale")
        sizeSlider?.doubleValue = scale == 0 ? 1 : scale
        let panel = UserDefaults.standard.double(forKey: "panelScale")
        panelSlider?.doubleValue = panel == 0 ? 1 : panel
        quotaSwitch?.state = Display.showQuotaInBar ? .on : .off
        menuBarSwitch?.state = Display.menuBarFiveHour != "off" ? .on : .off
    }

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

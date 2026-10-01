import AppKit

/// Hlavní okno appky — otevře se kliknutím na appku ve Finderu/Docku
/// (reopen) nebo při ručním spuštění. Na šířku, dva sloupce: vlevo overlay
/// + zobrazování, vpravo spend + účty + quit. Resizovatelné, velikost si
/// pamatuje (frame autosave); obsah se při změně velikosti přeskládá.
final class MainWindowController: NSObject, NSWindowDelegate {
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

    private static let defaultSize = NSSize(width: 760, height: 520)
    private static let minSize = NSSize(width: 620, height: 480)
    private let margin: CGFloat = 24
    private let rowStep: CGFloat = 36

    /// Sloupec: x a šířka, do kterých řádky kreslí.
    private struct Column { let x: CGFloat; let w: CGFloat }

    func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "NotchOverlay"
            w.isReleasedWhenClosed = false
            w.minSize = Self.minSize
            w.delegate = self
            // Pamatuje si velikost a pozici; při prvním otevření se vycentruje.
            if !w.setFrameUsingName("NotchOverlaySettings") { w.center() }
            w.setFrameAutosaveName("NotchOverlaySettings")
            window = w
        }
        // obsah se staví při každém otevření — stavy účtů se mění mimo appku
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        loadSpend()
    }

    /// Přeskládá obsah na aktuální velikost okna (resize, změna stavu účtů).
    private func rebuild() {
        guard let window else { return }
        window.contentView = buildContent(size: window.contentLayoutRect.size)
        applyControlStates()
        if let s = spendCache { applySpend(s) }
    }

    func windowDidResize(_ notification: Notification) {
        rebuild()
    }

    // MARK: - Řádky

    private func label(_ text: String, in col: Column, y: CGFloat, v: NSView) {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: col.x, y: y + 4, width: col.w * 0.55, height: 20)
        l.lineBreakMode = .byTruncatingTail
        v.addSubview(l)
    }

    private func sectionHeader(_ text: String, in col: Column, y: CGFloat, v: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: col.x, y: y, width: col.w, height: 14)
        v.addSubview(l)
    }

    private func switchRow(_ v: NSView, col: Column, label text: String, y: CGFloat,
                           action: Selector) -> NSSwitch {
        label(text, in: col, y: y, v: v)
        let s = NSSwitch(frame: NSRect(x: col.x + col.w - 38, y: y, width: 38, height: 24))
        s.target = self
        s.action = action
        v.addSubview(s)
        return s
    }

    private func accountRow(_ v: NSView, col: Column, name: String, status: String, y: CGFloat,
                            buttonTitle: String?, action: Selector?,
                            warning: Bool = false, tooltip: String? = nil) {
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.frame = NSRect(x: col.x, y: y + 3, width: 90, height: 18)
        v.addSubview(l)
        let st = NSTextField(labelWithString: status)
        st.font = .systemFont(ofSize: 11)
        st.textColor = warning ? .systemOrange
            : status.hasPrefix("signed in") ? .systemGreen : .secondaryLabelColor
        st.toolTip = tooltip ?? status
        st.lineBreakMode = .byTruncatingTail
        st.frame = NSRect(x: col.x + 94, y: y + 4, width: max(40, col.w - 94 - 98), height: 16)
        v.addSubview(st)
        if let buttonTitle, let action {
            let b = NSButton(title: buttonTitle, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.frame = NSRect(x: col.x + col.w - 90, y: y, width: 90, height: 24)
            v.addSubview(b)
        }
    }

    /// Řádek se sliderem (měřítko) + tlačítkem Reset. Vrací slider, ať jde nastavit hodnota.
    private func sliderRow(_ v: NSView, col: Column, label text: String, y: CGFloat,
                           min: Double, max: Double, action: Selector, reset: Selector) -> NSSlider {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: col.x, y: y + 4, width: 110, height: 20)
        v.addSubview(l)
        let sliderX = col.x + 118
        let slider = NSSlider(value: 1, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: sliderX, y: y, width: Swift.max(60, col.x + col.w - 66 - sliderX), height: 24)
        v.addSubview(slider)
        let b = NSButton(title: "Reset", target: self, action: reset)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.frame = NSRect(x: col.x + col.w - 58, y: y, width: 58, height: 22)
        v.addSubview(b)
        return slider
    }

    /// Index v popupu „Per session": 0 off, 1 tokens, 2 spend, 3 obojí.
    private static func perSessionIndex() -> Int {
        (Display.showSessionTokens ? 1 : 0) + (Display.showSessionSpend ? 2 : 0)
    }

    /// Řádek s popup výběrem; disabled položky zůstávají viditelné („soon").
    private func popupRow(_ v: NSView, col: Column, label text: String, y: CGFloat,
                          items: [(title: String, enabled: Bool)],
                          selected: Int, action: Selector) {
        label(text, in: col, y: y, v: v)
        let pw = min(150, col.w * 0.45)
        let popup = NSPopUpButton(frame: NSRect(x: col.x + col.w - pw, y: y, width: pw, height: 26))
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
    private func spendRow(_ v: NSView, col: Column, label text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: col.x, y: y, width: 120, height: 18)
        v.addSubview(l)
        let val = NSTextField(labelWithString: "…")
        val.font = .systemFont(ofSize: 12, weight: .medium)
        val.alignment = .right
        val.textColor = .secondaryLabelColor
        val.frame = NSRect(x: col.x + 120, y: y, width: col.w - 120, height: 18)
        v.addSubview(val)
        return val
    }

    // MARK: - Layout

    private func buildContent(size: NSSize) -> NSView {
        let width = size.width, height = size.height
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        let gap: CGFloat = 32
        let colW = (width - 2 * margin - gap) / 2
        let left = Column(x: margin, w: colW)
        let right = Column(x: margin + colW + gap, w: colW)

        // Hlavička: ikona + název + podtitul v jednom řádku přes celou šířku.
        var y = height - 16 - 40
        let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 40, height: 40))
        icon.image = NSApp.applicationIconImage
        v.addSubview(icon)
        let title = NSTextField(labelWithString: "NotchOverlay")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: margin + 50, y: y + 19, width: width - margin * 2 - 50, height: 22)
        v.addSubview(title)
        let subtitle = NSTextField(labelWithString: "Dynamic Island for AI coding agents")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: margin + 50, y: y + 1, width: width - margin * 2 - 50, height: 16)
        v.addSubview(subtitle)
        y -= 28
        let top = y

        // --- levý sloupec: OVERLAY + DISPLAY ---
        y = top
        sectionHeader("OVERLAY", in: left, y: y, v: v); y -= 30
        overlaySwitch = switchRow(v, col: left, label: "Island in the notch", y: y,
                                  action: #selector(toggleOverlay(_:))); y -= rowStep
        soundsSwitch = switchRow(v, col: left, label: "Sounds", y: y,
                                 action: #selector(toggleSounds(_:))); y -= rowStep
        sizeSlider = sliderRow(v, col: left, label: "Island size", y: y, min: 0.7, max: 1.5,
                               action: #selector(sizeChanged(_:)),
                               reset: #selector(resetSize(_:))); y -= rowStep
        panelSlider = sliderRow(v, col: left, label: "Panel size", y: y, min: 0.8, max: 1.6,
                                action: #selector(panelSizeChanged(_:)),
                                reset: #selector(resetPanelSize(_:))); y -= rowStep

        y -= 10
        sectionHeader("DISPLAY", in: left, y: y, v: v); y -= 30
        popupRow(v, col: left, label: "Per session", y: y,
                 items: [("Off", true), ("Tokens", true), ("Spend", true), ("Tokens + spend", true)],
                 selected: Self.perSessionIndex(), action: #selector(perSessionChanged(_:))); y -= rowStep
        quotaSwitch = switchRow(v, col: left, label: "Quota in the bar", y: y,
                                action: #selector(toggleQuota(_:))); y -= rowStep
        popupRow(v, col: left, label: "Second line", y: y,
                 items: [("None", true), ("Codex", true), ("Fable 5", true),
                         ("Gemini (soon)", false)],
                 selected: ["none", "codex", "fable", "gemini"].firstIndex(of: Display.headerSecondLine) ?? 0,
                 action: #selector(secondLineChanged(_:))); y -= rowStep
        menuBarSwitch = switchRow(v, col: left, label: "5h session in menu bar", y: y,
                                  action: #selector(toggleMenuBar(_:))); y -= rowStep
        popupRow(v, col: left, label: "Menu bar style", y: y,
                 items: [("Usage %", true), ("Reset time", true)],
                 selected: ["pct", "reset"].firstIndex(of: Display.menuBarFiveHourStyle) ?? 0,
                 action: #selector(menuBarStyleChanged(_:)))

        // --- pravý sloupec: SPEND + ACCOUNTS ---
        y = top
        sectionHeader("SPEND", in: right, y: y, v: v); y -= 28
        spend24 = spendRow(v, col: right, label: "Last 24h", y: y);      y -= 26
        spend7 = spendRow(v, col: right, label: "Last 7 days", y: y);    y -= 26
        spend31 = spendRow(v, col: right, label: "Last 31 days", y: y);  y -= 26
        spendYear = spendRow(v, col: right, label: "This year", y: y);   y -= 22
        let spendNote = NSTextField(labelWithString: "Estimate from local transcripts.")
        spendNote.font = .systemFont(ofSize: 11)
        spendNote.textColor = .secondaryLabelColor
        spendNote.frame = NSRect(x: right.x, y: y, width: right.w, height: 14)
        v.addSubview(spendNote)
        y -= 34

        sectionHeader("ACCOUNTS", in: right, y: y, v: v); y -= 30
        let claudeSt = claudeStatus?() ?? "checking…"
        let claudeIn = claudeSt.hasPrefix("signed in")
        let claudeExpired = claudeSt.contains("expired")
        accountRow(v, col: right, name: "Claude", status: claudeSt, y: y,
                   buttonTitle: claudeIn ? "Sign out" : "Sign in…",
                   action: claudeIn ? #selector(signOutClaude(_:)) : #selector(signIn(_:)),
                   warning: claudeExpired,
                   tooltip: claudeExpired
                       ? "Quotas are borrowed from Claude Code, whose token expired. NotchOverlay can't refresh it without logging Claude Code out. Sign in here and NotchOverlay keeps its own token fresh automatically."
                       : nil)
        y -= 30
        let codex = Providers.codex()
        accountRow(v, col: right, name: "Codex CLI", status: codex.label, y: y,
                   buttonTitle: !codex.installed ? nil : (codex.signedIn ? "Sign out" : "Sign in…"),
                   action: !codex.installed ? nil
                         : (codex.signedIn ? #selector(signOutCodex(_:)) : #selector(signInCodex(_:))))
        y -= 30
        let gemini = Providers.gemini()
        accountRow(v, col: right, name: "Gemini CLI", status: gemini.label, y: y,
                   buttonTitle: !gemini.installed ? nil : (gemini.signedIn ? "Sign out" : "Sign in…"),
                   action: !gemini.installed ? nil
                         : (gemini.signedIn ? #selector(signOutGemini(_:)) : #selector(signInGemini(_:))))

        // Quit dole vpravo — ukotvený ke spodní hraně okna.
        let quitY = margin
        let quit = NSButton(title: "Quit NotchOverlay", target: self, action: #selector(quit(_:)))
        quit.bezelStyle = .rounded
        quit.hasDestructiveAction = true
        quit.frame = NSRect(x: right.x, y: quitY + 18, width: right.w, height: 32)
        v.addSubview(quit)
        let note = NSTextField(labelWithString: "Quit stops the app until your next login (or manual launch).")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byTruncatingTail
        note.frame = NSRect(x: right.x, y: quitY, width: right.w, height: 14)
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

    // MARK: - Akce

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

    /// Stav účtu se změnil mimo okno (kvóty, login) — překreslit, pokud je otevřené.
    func accountsChanged() {
        refresh()
    }

    /// Překreslí obsah okna (stavy účtů) bez přecentrování.
    private func refresh() {
        guard let window, window.isVisible else { return }
        rebuild()
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

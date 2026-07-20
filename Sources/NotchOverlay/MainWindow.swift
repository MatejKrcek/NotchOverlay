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
    private var tokensSwitch: NSSwitch?
    private var quotaSwitch: NSSwitch?
    private var spend24: NSTextField?
    private var spend7: NSTextField?
    private var spend31: NSTextField?
    private var spendYear: NSTextField?
    private let spendStats = SpendStats()
    private var spendCache: SpendSummary?

    func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 756),
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
        let scale = UserDefaults.standard.double(forKey: "islandScale")
        sizeSlider?.doubleValue = scale == 0 ? 1 : scale
        tokensSwitch?.state = Display.showSessionTokens ? .on : .off
        quotaSwitch?.state = Display.showQuotaInBar ? .on : .off
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
        st.textColor = status == "signed in" ? .systemGreen : .secondaryLabelColor
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
        let width = 400.0, height = 756.0
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

        let sizeLabel = NSTextField(labelWithString: "Island size")
        sizeLabel.frame = NSRect(x: 24, y: y + 4, width: 120, height: 20)
        v.addSubview(sizeLabel)
        let slider = NSSlider(value: 1, minValue: 0.7, maxValue: 1.5,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 150, y: y, width: width - 150 - 24 - 66, height: 24)
        v.addSubview(slider)
        sizeSlider = slider
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSize(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)
        reset.frame = NSRect(x: width - 24 - 58, y: y, width: 58, height: 22)
        v.addSubview(reset)
        y -= 36

        tokensSwitch = switchRow(v, label: "Tokens per session", y: y,
                                 action: #selector(toggleTokens(_:)))
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
        accountRow(v, name: "Claude", status: claudeSt, y: y,
                   buttonTitle: claudeSt == "signed in" ? "Sign out" : "Sign in…",
                   action: claudeSt == "signed in" ? #selector(signOutClaude(_:))
                                                   : #selector(signIn(_:)))
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

    @objc private func toggleTokens(_ sender: NSSwitch) {
        Display.showSessionTokens = sender.state == .on
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
        overlaySwitch?.state = (isOverlayOn?() ?? true) ? .on : .off
        soundsSwitch?.state = Sounds.shared.enabled ? .on : .off
        let scale = UserDefaults.standard.double(forKey: "islandScale")
        sizeSlider?.doubleValue = scale == 0 ? 1 : scale
        tokensSwitch?.state = Display.showSessionTokens ? .on : .off
        quotaSwitch?.state = Display.showQuotaInBar ? .on : .off
        loadSpend()
    }

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

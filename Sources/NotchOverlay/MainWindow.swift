import AppKit

/// Hlavní okno appky — otevře se kliknutím na appku ve Finderu/Docku
/// (reopen) nebo při ručním spuštění. Overlay on/off, zvuky, velikost,
/// zobrazování (tokeny, kvóta), účty (Claude/Codex/Gemini), quit.
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    var isOverlayOn: (() -> Bool)?
    var setOverlayOn: ((Bool) -> Void)?
    var onSignIn: (() -> Void)?
    var onSizeChange: (() -> Void)?
    /// Stav přihlášení ke Claude ("signed in" / "not signed in" / "checking…").
    var claudeStatus: (() -> String)?

    private var window: NSWindow?
    private var overlaySwitch: NSSwitch?
    private var soundsSwitch: NSSwitch?
    private var sizeSlider: NSSlider?
    private var tokensSwitch: NSSwitch?
    private var quotaSwitch: NSSwitch?

    func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
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

    private func buildContent() -> NSView {
        let width = 400.0, height = 560.0
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let icon = NSImageView(frame: NSRect(x: width / 2 - 32, y: height - 80, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        v.addSubview(icon)

        let title = NSTextField(labelWithString: "NotchOverlay")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: height - 110, width: width, height: 24)
        v.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Dynamic Island for AI coding agents")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: height - 130, width: width, height: 16)
        v.addSubview(subtitle)

        overlaySwitch = switchRow(v, label: "Island in the notch", y: 384,
                                  action: #selector(toggleOverlay(_:)))
        soundsSwitch = switchRow(v, label: "Sounds", y: 348,
                                 action: #selector(toggleSounds(_:)))

        let sizeLabel = NSTextField(labelWithString: "Island size")
        sizeLabel.frame = NSRect(x: 24, y: 316, width: 120, height: 20)
        v.addSubview(sizeLabel)
        let slider = NSSlider(value: 1, minValue: 1, maxValue: 1.5,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 150, y: 312, width: width - 150 - 24 - 66, height: 24)
        v.addSubview(slider)
        sizeSlider = slider
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSize(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)
        reset.frame = NSRect(x: width - 24 - 58, y: 312, width: 58, height: 22)
        v.addSubview(reset)

        tokensSwitch = switchRow(v, label: "Tokens per session", y: 276,
                                 action: #selector(toggleTokens(_:)))
        quotaSwitch = switchRow(v, label: "Quota in the bar", y: 240,
                                action: #selector(toggleQuota(_:)))

        let accounts = NSTextField(labelWithString: "ACCOUNTS")
        accounts.font = .systemFont(ofSize: 10, weight: .semibold)
        accounts.textColor = .secondaryLabelColor
        accounts.frame = NSRect(x: 24, y: 202, width: 200, height: 14)
        v.addSubview(accounts)

        accountRow(v, name: "Claude", status: claudeStatus?() ?? "checking…",
                   y: 170, buttonTitle: "Sign in…", action: #selector(signIn(_:)))
        let codex = Providers.codex()
        accountRow(v, name: "Codex CLI", status: codex.label, y: 140,
                   buttonTitle: codex.installed ? "Sign in…" : nil,
                   action: codex.installed ? #selector(signInCodex(_:)) : nil)
        let gemini = Providers.gemini()
        accountRow(v, name: "Gemini CLI", status: gemini.label, y: 110,
                   buttonTitle: gemini.installed ? "Sign in…" : nil,
                   action: gemini.installed ? #selector(signInGemini(_:)) : nil)

        let quit = NSButton(title: "Quit NotchOverlay", target: self, action: #selector(quit(_:)))
        quit.bezelStyle = .rounded
        quit.hasDestructiveAction = true
        quit.frame = NSRect(x: 24, y: 38, width: width - 48, height: 32)
        v.addSubview(quit)

        let note = NSTextField(wrappingLabelWithString:
            "Quit stops the app until your next login (or manual launch).")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 24, y: 14, width: width - 48, height: 16)
        v.addSubview(note)

        return v
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

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

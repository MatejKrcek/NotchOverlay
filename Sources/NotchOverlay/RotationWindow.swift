import AppKit

/// Okno „Account rotation": účty v pořadí priority, práh přepnutí, co dělat,
/// když dojdou Claude účty. Obsah se staví v kódu a přestaví se při každé změně.
final class RotationWindowController: NSObject, NSWindowDelegate {
    static let shared = RotationWindowController()

    /// Volá se po zapnutí/vypnutí rotace — appka přepne zdroj kvót v islandu.
    var onEnabledChange: (() -> Void)?

    private var window: NSWindow?
    private var message: String?
    private let width: CGFloat = 640
    private let margin: CGFloat = 20
    private let rowH: CGFloat = 34

    func present() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Account rotation"
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
            w.center()
        }
        message = nil
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        AccountRotation.shared.refreshNow()
    }

    /// Stav účtů se změnil — překreslit, jen když je okno vidět.
    func refresh() {
        guard let window, window.isVisible else { return }
        rebuild()
    }

    // MARK: - Layout

    private func rebuild() {
        guard let window else { return }
        let order = RotationPrefs.order
        let height: CGFloat = 280 + CGFloat(order.count) * rowH + (message == nil ? 0 : 24)
        var frame = window.frame
        let newSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        frame.origin.y += frame.height - newSize.height   // horní hrana zůstává na místě
        frame.size = newSize
        window.setFrame(frame, display: true)

        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let inner = width - 2 * margin
        var y = height - 40

        // Zapnutí + práh + Codex akce
        addLabel(v, "Automatic rotation", x: margin, y: y + 3, w: 200, bold: true)
        let sw = NSSwitch(frame: NSRect(x: width - margin - 38, y: y, width: 38, height: 24))
        sw.state = RotationPrefs.enabled ? .on : .off
        sw.target = self
        sw.action = #selector(toggleEnabled(_:))
        v.addSubview(sw)
        y -= 32

        addLabel(v, "Switch when usage reaches", x: margin, y: y + 4, w: 260)
        let thresholds = [80, 90, 95, 100]
        let tp = popup(v, items: thresholds.map { "\($0)%" },
                       selected: thresholds.firstIndex(of: RotationPrefs.threshold) ?? 2,
                       x: width - margin - 200, y: y, action: #selector(thresholdChanged(_:)))
        tp.toolTip = "An account counts as used up when its 5-hour or weekly window reaches this level."
        y -= 32

        addLabel(v, "When all Claude accounts are out", x: margin, y: y + 4, w: 260)
        popup(v, items: ["Notify me", "Open Codex in Terminal"],
              selected: RotationPrefs.codexAction == "open" ? 1 : 0,
              x: width - margin - 200, y: y, action: #selector(codexActionChanged(_:)))
        y -= 40

        addLabel(v, "PRIORITY - TOP IS USED FIRST", x: margin, y: y, w: inner, small: true)
        y -= rowH - 4

        let rotation = AccountRotation.shared
        for (i, key) in order.enumerated() {
            let isCodex = key == RotationPrefs.codexKey
            let id = isCodex ? "" : String(key.dropFirst("claude:".count))
            let name = isCodex ? "Codex CLI" : (rotation.label(for: id) ?? id)
            let status = isCodex ? rotation.codexStatusText() : rotation.statusText(for: id)
            let isActive = !isCodex && rotation.activeId == id
            let isTarget = rotation.currentTarget == key && RotationPrefs.enabled

            addLabel(v, "\(i + 1).", x: margin, y: y + 5, w: 22, secondary: true)
            let n = addLabel(v, name + (isActive ? "  ● in Claude Code" : ""), x: margin + 22, y: y + 12, w: 330, bold: isTarget)
            n.textColor = isActive ? .systemGreen : .labelColor
            let st = addLabel(v, status.text, x: margin + 22, y: y - 3, w: 340, small: true)
            st.textColor = status.warning ? .systemOrange : .secondaryLabelColor
            st.toolTip = status.text

            var bx = width - margin
            func button(_ title: String, _ w: CGFloat, _ action: Selector, enabled: Bool = true, tip: String? = nil) {
                bx -= w
                let b = NSButton(title: title, target: self, action: action)
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.font = .systemFont(ofSize: 11)
                b.frame = NSRect(x: bx, y: y + 2, width: w, height: 24)
                b.identifier = NSUserInterfaceItemIdentifier(key)
                b.isEnabled = enabled
                b.toolTip = tip
                v.addSubview(b)
                bx -= 4
            }
            if isCodex {
                button("Open", 60, #selector(openCodex(_:)), enabled: Providers.codex().signedIn,
                       tip: "Open Codex in Terminal, in the folder of your latest session.")
            } else {
                button("Remove", 70, #selector(removeAccount(_:)),
                       tip: "Forget this account here. Claude Code's own login stays as it is.")
                button("Use", 50, #selector(useAccount(_:)), enabled: !isActive,
                       tip: "Switch Claude Code to this account now. With rotation on, a higher-priority account with room left takes over again.")
            }
            button("↓", 30, #selector(moveDown(_:)), enabled: i < order.count - 1)
            button("↑", 30, #selector(moveUp(_:)), enabled: i > 0)
            y -= rowH
        }

        y -= 8
        let add = NSButton(title: "Add current Claude Code login", target: self, action: #selector(addCurrent(_:)))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: margin, y: y - 4, width: 240, height: 28)
        v.addSubview(add)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshNow(_:)))
        refresh.bezelStyle = .rounded
        refresh.frame = NSRect(x: margin + 248, y: y - 4, width: 90, height: 28)
        v.addSubview(refresh)
        y -= 30

        if let message {
            let m = addLabel(v, message, x: margin, y: y, w: inner, small: true)
            m.textColor = .systemBlue
            y -= 24
        }

        var lines = [
            "To add an account: run /login in Claude Code with it, then click Add current Claude Code login. Repeat for each account.",
            "Switching changes the login Claude Code uses. New sessions pick it up; restart sessions that are already running.",
        ]
        if let e = rotation.lastEvent { lines.insert("Last: \(e)", at: 0) }
        let help = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: margin, y: 12, width: inner, height: max(40, y - 16))
        v.addSubview(help)

        window.contentView = v
    }

    @discardableResult
    private func addLabel(_ v: NSView, _ text: String, x: CGFloat, y: CGFloat, w: CGFloat,
                          bold: Bool = false, small: Bool = false, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = small ? .systemFont(ofSize: 11) : .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        if secondary || small { l.textColor = .secondaryLabelColor }
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: x, y: y, width: w, height: small ? 15 : 18)
        v.addSubview(l)
        return l
    }

    @discardableResult
    private func popup(_ v: NSView, items: [String], selected: Int, x: CGFloat, y: CGFloat,
                       action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: 200, height: 26))
        p.addItems(withTitles: items)
        p.selectItem(at: selected)
        p.target = self
        p.action = action
        v.addSubview(p)
        return p
    }

    // MARK: - Akce

    private func key(_ sender: NSButton) -> String { sender.identifier?.rawValue ?? "" }
    private func accountId(_ sender: NSButton) -> String { String(key(sender).dropFirst("claude:".count)) }

    @objc private func toggleEnabled(_ sender: NSSwitch) {
        RotationPrefs.enabled = sender.state == .on
        // Kdo zapne rotaci, chce ji vidět — prázdnou druhou řádku islandu jí předat.
        if RotationPrefs.enabled, Display.headerSecondLine == "none" { Display.headerSecondLine = "rotation" }
        AccountRotation.shared.settingsChanged()
        onEnabledChange?()
        rebuild()
    }

    @objc private func thresholdChanged(_ sender: NSPopUpButton) {
        RotationPrefs.threshold = [80, 90, 95, 100][max(0, sender.indexOfSelectedItem)]
        AccountRotation.shared.settingsChanged()
    }

    @objc private func codexActionChanged(_ sender: NSPopUpButton) {
        RotationPrefs.codexAction = sender.indexOfSelectedItem == 1 ? "open" : "notify"
    }

    @objc private func moveUp(_ sender: NSButton) { AccountRotation.shared.move(key(sender), by: -1) }
    @objc private func moveDown(_ sender: NSButton) { AccountRotation.shared.move(key(sender), by: 1) }

    @objc private func useAccount(_ sender: NSButton) {
        AccountRotation.shared.use(id: accountId(sender))
    }

    @objc private func removeAccount(_ sender: NSButton) {
        let id = accountId(sender)
        let alert = NSAlert()
        alert.messageText = "Remove \(AccountRotation.shared.label(for: id) ?? "this account") from rotation?"
        alert.informativeText = "NotchOverlay forgets its saved login. Claude Code stays logged in as it is now."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AccountRotation.shared.remove(id: id)
    }

    @objc private func openCodex(_ sender: NSButton) { AccountRotation.shared.openCodex() }

    @objc private func addCurrent(_ sender: NSButton) {
        message = "Saving the current Claude Code login…"
        rebuild()
        AccountRotation.shared.addCurrentLogin { [weak self] msg in
            self?.message = msg
            self?.rebuild()
            MainWindowController.shared.accountsChanged()
        }
    }

    @objc private func refreshNow(_ sender: NSButton) { AccountRotation.shared.refreshNow() }
}

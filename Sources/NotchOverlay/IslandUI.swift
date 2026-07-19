import AppKit

/// Zbývající čas do resetu: "42m", "3h 58m", "2d 1h".
func remainingString(until date: Date) -> String {
    let s = max(0, Int(date.timeIntervalSinceNow))
    let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Kořen okna: okno je trvale velké (kvůli plynulé animaci se nikdy neresizuje),
/// ale klikatelný je jen samotný island — zbytek propouští myš skrz.
final class PassthroughRootView: NSView {
    weak var island: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        if let island, v === self || !v.isDescendant(of: island) { return nil }
        return v
    }
}

/// Černý tvar islandu — flipped (y odshora), hover tracking, kontextové menu.
final class IslandShapeView: NSView {
    weak var controller: IslandController?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { controller?.hoverChanged(inside: true) }
    override func mouseExited(with event: NSEvent) { controller?.hoverChanged(inside: false) }
    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(at: event, in: self) }
}

final class SessionRowView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class IslandController: NSObject {
    private var panel: OverlayPanel?
    private var screen: NSScreen?
    private var hasNotch = false
    private var notchWidth: CGFloat = 0
    private var topInset: CGFloat = 32

    private var islandView: IslandShapeView!
    private var stripView: NSView!
    private var listView: FlippedContainer!

    private var sessions: [AgentSession] = []
    private var usage = UsageSummary()
    private var quota: QuotaStatus?          // poslední úspěšná data (drží se i při výpadku)
    private var quotaState: QuotaFetchState = .starting
    var onSignInRequested: (() -> Void)?
    /// Overlay lze schovat z hlavního okna; stav se drží i přes rebuild obrazovek.
    private(set) var overlayVisible = true
    private var expanded = false
    private var animating = false
    private var pendingRender = false
    private var refreshTimer: Timer?

    private let expandedWidth: CGFloat = 440
    private let rowHeight: CGFloat = 46
    private let headerHeight: CGFloat = 26
    private let maxVisibleRows = 8
    /// Paid: měřítko šířky islandu — roste jen do stran (křídla), výška je
    /// fixní podle notche.
    private var sizeScale: CGFloat {
        let v = UserDefaults.standard.double(forKey: "islandScale")
        return v == 0 ? 1 : CGFloat(min(max(v, 1.0), 1.5))
    }

    /// Křídla v liště vedle notche — jen tak široká, jak potřebuje obsah,
    /// aby zakryla co nejméně menu baru (a nic pod ním).
    private var leftWingWidth: CGFloat { (CGFloat(min(max(sessions.count, 1), 5)) * 13 + 34) * sizeScale }
    private var rightWingWidth: CGFloat { 120 * sizeScale }
    /// Odstup obsahu pravého křídla od hrany notche, aby se „5h" neschovávalo pod výřezem.
    private let notchGap: CGFloat = 20

    final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: - Lifecycle

    func setUp() {
        rebuildForCurrentScreen()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.expanded, !self.animating else { return }
            self.renderList()
        }
    }

    @objc private func screensChanged() { rebuildForCurrentScreen() }

    func update(sessions: [AgentSession]) {
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        render()
    }

    func update(usage: UsageSummary) {
        guard usage != self.usage else { return }
        self.usage = usage
        render()
    }

    func update(quotaState: QuotaFetchState) {
        guard quotaState != self.quotaState else { return }
        self.quotaState = quotaState
        if case .ok(let status) = quotaState { quota = status }
        render()
    }

    // MARK: - Geometrie

    private var compactWidth: CGFloat {
        hasNotch ? notchWidth + leftWingWidth + rightWingWidth : 300
    }
    private var panelWidth: CGFloat { max(expandedWidth, compactWidth) + 8 }
    private var panelHeight: CGFloat {
        topInset + headerHeight + CGFloat(maxVisibleRows) * rowHeight + 16
    }

    private func rebuildForCurrentScreen() {
        panel?.close()
        panel = nil

        let builtIn = NSScreen.screens.first { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        guard let screen = builtIn ?? NSScreen.main ?? NSScreen.screens.first else { return }
        self.screen = screen

        hasNotch = screen.safeAreaInsets.top > 0
        topInset = hasNotch ? screen.safeAreaInsets.top : 34
        if hasNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - l.width - r.width
        } else {
            notchWidth = 0
        }

        // Okno má trvale plnou (expandovanou) velikost — animuje se jen island uvnitř.
        let sf = screen.frame
        let topY = hasNotch ? sf.maxY : screen.visibleFrame.maxY - 4
        let panelFrame = NSRect(
            x: sf.midX - panelWidth / 2, y: topY - panelHeight,
            width: panelWidth, height: panelHeight
        )

        let p = OverlayPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = PassthroughRootView(frame: NSRect(origin: .zero, size: panelFrame.size))
        root.wantsLayer = true

        islandView = IslandShapeView()
        islandView.controller = self
        islandView.wantsLayer = true
        islandView.layer?.backgroundColor = NSColor.black.cgColor
        islandView.layer?.masksToBounds = true
        islandView.layer?.cornerRadius = hasNotch ? 10 : 12
        if hasNotch {
            // horní hrana lícuje s okrajem displeje — zaoblené jen spodní rohy.
            // Pozor: islandView je flipped, takže „spodní" rohy jsou MaxY.
            islandView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        root.island = islandView
        root.addSubview(islandView)

        stripView = NSView()  // horní pruh (výška notche), obsah centrovaný vertikálně
        stripView.autoresizingMask = [.width]
        islandView.addSubview(stripView)

        listView = FlippedContainer()
        listView.alphaValue = 0
        islandView.addSubview(listView)

        islandView.frame = islandFrame(expanded: false, in: root.bounds.size)
        stripView.frame = NSRect(x: 0, y: 0, width: islandView.frame.width, height: topInset)

        p.contentView = root
        panel = p
        expanded = false
        animating = false
        renderStrip()
        renderList()
        if overlayVisible { p.orderFrontRegardless() }
    }

    func setVisible(_ visible: Bool) {
        overlayVisible = visible
        if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
    }

    /// Po změně islandScale v UserDefaults přestaví panel s novou geometrií.
    func sizeChanged() {
        rebuildForCurrentScreen()
    }

    private var visibleRowCount: Int { min(max(1, sessions.count), maxVisibleRows) }

    private func expandedHeight() -> CGFloat {
        topInset + headerHeight + CGFloat(visibleRowCount) * rowHeight + 12
    }

    /// Frame islandu v souřadnicích root view (root NENÍ flipped — y odspodu),
    /// ukotvený k horní hraně okna a vodorovně na střed.
    private func islandFrame(expanded: Bool, in rootSize: NSSize) -> NSRect {
        let w = expanded ? max(expandedWidth, compactWidth) : compactWidth
        let h = expanded ? expandedHeight() : topInset
        return NSRect(x: (rootSize.width - w) / 2, y: rootSize.height - h, width: w, height: h)
    }

    // MARK: - Hover

    func hoverChanged(inside: Bool) {
        if inside {
            setExpanded(true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if !self.islandScreenRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
                self.setExpanded(false)
            }
        }
    }

    private func islandScreenRect() -> NSRect {
        guard let panel else { return .zero }
        let f = islandView.frame
        return NSRect(
            x: panel.frame.minX + f.minX, y: panel.frame.minY + f.minY,
            width: f.width, height: f.height
        )
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value, let panel else { return }
        expanded = value
        if value { renderList() }  // čerstvý obsah ještě před odkrytím
        animating = true
        let target = islandFrame(expanded: value, in: panel.contentView!.bounds.size)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            islandView.animator().frame = target
            listView.animator().alphaValue = value ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.animating = false
            if self.pendingRender {
                self.pendingRender = false
                self.render()
            }
        })
    }

    // MARK: - Render (nikdy nesahá na frame okna; během animace se odkládá)

    private func render() {
        guard panel != nil else { return }
        if animating {
            pendingRender = true
            return
        }
        // šířka křídel / počet řádků se mohly změnit — dorovnat frame bez animace
        let f = islandFrame(expanded: expanded, in: panel!.contentView!.bounds.size)
        if islandView.frame != f { islandView.frame = f }
        renderStrip()
        renderList()
    }

    /// Lišta vedle notche: tečky v levém křídle, „5h X%" v pravém.
    /// Křídla jsou minimální, aby zbytek menu baru zůstal viditelný.
    private func renderStrip() {
        stripView.subviews.forEach { $0.removeFromSuperview() }
        let w = stripView.frame.width
        let h = stripView.frame.height

        let left = NSTextField(labelWithString: "")
        left.attributedStringValue = leftAttributed()
        left.alignment = .center
        left.lineBreakMode = .byClipping
        left.frame = NSRect(x: 6, y: (h - 16) / 2, width: leftWingWidth - 8, height: 16)
        left.autoresizingMask = [.maxXMargin]
        stripView.addSubview(left)

        let right = NSTextField(labelWithString: "")
        right.attributedStringValue = rightAttributed()
        right.alignment = .right  // do rohu pillu, ne doprostřed křídla
        right.lineBreakMode = .byClipping
        right.frame = NSRect(x: w - rightWingWidth + notchGap, y: (h - 18) / 2, width: rightWingWidth - notchGap - 16, height: 18)
        right.autoresizingMask = [.minXMargin]
        stripView.addSubview(right)
    }

    /// Rozbalený obsah: hlavička s kvótami + řádky sessions (flipped, y odshora).
    private func renderList() {
        guard panel != nil else { return }
        listView.subviews.forEach { $0.removeFromSuperview() }
        let w = max(expandedWidth, compactWidth)
        let h = expandedHeight() - topInset
        // Sedí pod lištou; x podle AKTUÁLNÍ šířky islandu + pružné okraje,
        // takže zůstává na středu i během animace roztahování.
        listView.frame = NSRect(x: (islandView.frame.width - w) / 2, y: topInset, width: w, height: h)
        listView.autoresizingMask = [.minXMargin, .maxXMargin]

        if case .signedOut = quotaState, quota == nil {
            let signIn = makeButton(title: "Sign in with Claude", color: .white)
            signIn.frame = NSRect(x: (w - 160) / 2, y: 3, width: 160, height: 20)
            signIn.target = self
            signIn.action = #selector(signInClicked)
            listView.addSubview(signIn)
        } else {
            let header = NSTextField(labelWithString: quotaHeaderText())
            header.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
            header.textColor = NSColor.white.withAlphaComponent(0.55)
            header.alignment = .center
            header.frame = NSRect(x: 12, y: 5, width: w - 24, height: 16)
            listView.addSubview(header)
        }

        if sessions.isEmpty {
            let empty = NSTextField(labelWithString: "No agents running")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = NSColor.white.withAlphaComponent(0.6)
            empty.alignment = .center
            empty.frame = NSRect(x: 0, y: headerHeight + 12, width: w, height: 20)
            listView.addSubview(empty)
            return
        }

        var y = headerHeight
        for session in sessions.prefix(maxVisibleRows) {
            let row = buildRow(session, width: w)
            row.frame.origin = NSPoint(x: 8, y: y + 2)
            listView.addSubview(row)
            y += rowHeight
        }
    }

    private func buildRow(_ s: AgentSession, width: CGFloat) -> NSView {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: width - 16, height: rowHeight - 4))
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        let termProgram = s.termProgram
        row.onClick = { Jump.toTerminal(termProgram: termProgram) }

        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 12, weight: .bold)
        dot.textColor = dotColor(s.state)
        dot.frame = NSRect(x: 10, y: (rowHeight - 4 - 16) / 2, width: 16, height: 16)
        row.addSubview(dot)

        let showButtons: Bool
        if case .permission = s.state { showButtons = true } else { showButtons = false }
        let rightReserved: CGFloat = showButtons ? 150 : 64

        let title = NSTextField(labelWithString: s.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 30, y: rowHeight - 4 - 20, width: row.frame.width - 30 - rightReserved, height: 16)
        row.addSubview(title)

        let sub = NSTextField(labelWithString: subtitle(for: s))
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = NSColor.white.withAlphaComponent(0.55)
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 30, y: 5, width: row.frame.width - 30 - rightReserved, height: 14)
        row.addSubview(sub)

        if showButtons {
            let deny = makeButton(title: "Deny", color: .systemRed)
            deny.frame = NSRect(x: row.frame.width - 146, y: (rowHeight - 4 - 22) / 2, width: 64, height: 22)
            deny.target = self
            deny.action = #selector(denyClicked(_:))
            deny.identifier = NSUserInterfaceItemIdentifier(s.id)
            row.addSubview(deny)

            let allow = makeButton(title: "Allow", color: .systemGreen)
            allow.frame = NSRect(x: row.frame.width - 76, y: (rowHeight - 4 - 22) / 2, width: 64, height: 22)
            allow.target = self
            allow.action = #selector(allowClicked(_:))
            allow.identifier = NSUserInterfaceItemIdentifier(s.id)
            row.addSubview(allow)
        } else {
            let time = NSTextField(labelWithString: elapsedString(since: s.lastActivity))
            time.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            time.textColor = NSColor.white.withAlphaComponent(0.45)
            time.alignment = .right
            time.frame = NSRect(x: row.frame.width - 62, y: (rowHeight - 4 - 14) / 2, width: 54, height: 14)
            row.addSubview(time)
        }
        return row
    }

    private func makeButton(title: String, color: NSColor) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 11, weight: .semibold)
        b.contentTintColor = color
        b.wantsLayer = true
        b.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        b.layer?.cornerRadius = 6
        b.isBordered = false
        return b
    }

    // MARK: - Texty a barvy

    private func leftAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        if sessions.isEmpty {
            s.append(NSAttributedString(string: "◦", attributes: [
                .foregroundColor: NSColor.gray, .font: font,
            ]))
            return s
        }
        for session in sessions.prefix(5) {
            s.append(NSAttributedString(string: "● ", attributes: [
                .foregroundColor: dotColor(session.state), .font: font,
            ]))
        }
        return s
    }

    /// „5h" malé a tlumené, procento velké bílé bold — dle mockupu.
    /// Pozn.: alignment MUSÍ být v paragraph stylu — NSTextField.alignment
    /// se u attributed stringů ignoruje.
    private func rightAttributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "5h ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .paragraphStyle: para,
        ]))
        let pct: String
        if let p = quota?.fiveHour?.pct { pct = "\(p)" }
        else if case .signedOut = quotaState { pct = "–" }
        else { pct = "?" }
        s.append(NSAttributedString(string: "\(pct)%", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]))
        return s
    }

    private func quotaHeaderText() -> String {
        guard let quota else {
            switch quotaState {
            case .starting: return "quota: loading…"
            case .rateLimited(let until): return "quota: rate limited · retry in \(remainingString(until: until))"
            case .signedOut: return "quota: not signed in"
            case .ok: return "quota: loading…"
            }
        }
        var parts: [String] = []
        if let fh = quota.fiveHour {
            var s = "5h: \(fh.pct)%"
            if let r = fh.resetsAt { s += " · resets in \(remainingString(until: r))" }
            parts.append(s)
        }
        if let wk = quota.sevenDay {
            var s = "week: \(wk.pct)%"
            if let r = wk.resetsAt { s += " · resets in \(remainingString(until: r))" }
            parts.append(s)
        }
        return parts.isEmpty ? "quota unavailable" : parts.joined(separator: "    ")
    }

    // modrá = pracuje, zelená = hotovo, oranžová = potřebuje tvou akci, červená = fail
    private func dotColor(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return .systemBlue
        case .stalled, .permission, .question: return .systemOrange
        case .failed: return .systemRed
        case .done: return .systemGreen
        case .idle: return .systemGray
        }
    }

    private func subtitle(for s: AgentSession) -> String {
        var status: String
        switch s.state {
        case .working(let what): status = "▶ \(what)"
        case .stalled(let what): status = "⏸ \(what) — waiting (permission?)"
        case .permission(let tool): status = "⚠ permission: \(tool)"
        case .question: status = "❓ waiting for your answer"
        case .failed(let what): status = "✕ failed: \(what)"
        case .done: status = "✓ done — click to jump"
        case .idle: status = "idle"
        }
        var parts = [status, s.project]
        if let b = s.branch { parts.append(b) }
        if !s.model.isEmpty { parts.append(s.model) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Akce

    @objc private func signInClicked() { onSignInRequested?() }

    @objc private func allowClicked(_ sender: NSButton) { answer(sender, allow: true) }
    @objc private func denyClicked(_ sender: NSButton) { answer(sender, allow: false) }

    private func answer(_ sender: NSButton, allow: Bool) {
        guard let id = sender.identifier?.rawValue,
              let session = sessions.first(where: { $0.id == id }) else { return }
        if !allow { Sounds.shared.denied() }
        Jump.answerPermission(termProgram: session.termProgram, allow: allow)
    }

    func showMenu(at event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Sounds.shared.enabled ? .on : .off
        menu.addItem(sounds)
        let login = NSMenuItem(title: "Sign in with Claude…", action: #selector(signInClicked), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchOverlay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func toggleSounds() { Sounds.shared.enabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

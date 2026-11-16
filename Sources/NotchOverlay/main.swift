import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let island = IslandController()
    private let monitor = SessionMonitor()
    private let usage = UsageStats()
    private let hooks = HookIngest()
    private let quota = QuotaFetcher()
    private var lastQuota: QuotaStatus?
    private var quotaFetchState: QuotaFetchState = .starting
    private var latestSessions: [AgentSession] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        island.setUp()
        MenuBarController.shared.start()
        WeatherController.shared.start()

        monitor.onUpdate = { [weak self] sessions in
            self?.latestSessions = sessions
            self?.island.update(sessions: sessions)
            Self.dumpState(sessions, quota: self?.lastQuota)
        }
        monitor.onStateChange = { session, previous in
            guard previous != nil else { return }  // start appky nemá troubit na existující sessions
            switch session.state {
            case .permission: Sounds.shared.permission()
            case .question: Sounds.shared.question()
            case .done:
                if case .some(.working) = previous { Sounds.shared.done() }
                else if case .some(.stalled) = previous { Sounds.shared.done() }
            case .failed: Sounds.shared.denied()
            case .working:
                if previous == .some(.idle) || previous == .some(.done) { Sounds.shared.sessionStart() }
            default: break
            }
        }
        usage.onUpdate = { [weak self] summary in
            self?.island.update(usage: summary)
        }
        hooks.onEvent = { [weak self] sessionId, state, term, ended in
            self?.monitor.applyHookEvent(sessionId: sessionId, state: state, termProgram: term, ended: ended)
        }
        // Rotace účtů: když je zapnutá a ví, který účet má Claude Code, kvóty
        // v islandu/menu baru dodává ona (pro aktivní účet) a QuotaFetcher stojí.
        let rotation = AccountRotation.shared
        quota.isPaused = { rotation.drivesQuota }
        rotation.latestCwd = { [weak self] in
            self?.latestSessions.max(by: { $0.lastActivity < $1.lastActivity })?.cwd
        }
        rotation.onActiveQuota = { [weak self] state in self?.quota.onState?(state) }
        rotation.onLoginChange = { [weak self] in self?.quota.credentialsChanged() }
        rotation.onChange = { [weak self] in
            self?.island.contentChanged()
            RotationWindowController.shared.refresh()
            MainWindowController.shared.accountsChanged()
        }
        RotationWindowController.shared.onEnabledChange = { [weak self] in
            self?.island.sizeChanged()  // druhá řádka hlavičky se mohla zapnout
            // vypnutá rotace → hned zpátky na běžný fetch kvót
            if !rotation.drivesQuota { self?.quota.credentialsChanged() }
        }

        quota.onState = { [weak self] state in
            guard let self else { return }
            self.island.update(quotaState: state)
            MenuBarController.shared.update(quotaState: state)
            let before = self.claudeStatusLabel()
            let beforeQuota = self.lastQuota
            self.quotaFetchState = state
            if case .ok(let status) = state { self.lastQuota = status }
            // Otevřené nastavení ať hned ukáže nový stav účtu (např. po in-app loginu)
            // i nové procento okna u přihlášeného účtu.
            if self.claudeStatusLabel() != before || self.lastQuota != beforeQuota {
                MainWindowController.shared.accountsChanged()
            }
        }
        island.onSignInRequested = { [weak self] in
            LoginController.shared.onSuccess = {
                UserDefaults.standard.removeObject(forKey: "claudeSignedOut")
                self?.quota.credentialsChanged()
            }
            LoginController.shared.present()
        }

        MainWindowController.shared.isOverlayOn = { [weak self] in
            self?.island.overlayVisible ?? true
        }
        MainWindowController.shared.setOverlayOn = { [weak self] on in
            self?.island.setVisible(on)
            UserDefaults.standard.set(!on, forKey: "overlayHidden")
        }
        MainWindowController.shared.onSignIn = { [weak self] in
            LoginController.shared.onSuccess = {
                UserDefaults.standard.removeObject(forKey: "claudeSignedOut")
                self?.quota.credentialsChanged()
            }
            LoginController.shared.present()
        }
        MainWindowController.shared.onSignOutClaude = { [weak self] in
            Providers.signOutClaude()
            self?.quota.credentialsChanged()
        }
        MainWindowController.shared.onSizeChange = { [weak self] in
            self?.island.sizeChanged()
        }
        MainWindowController.shared.claudeStatus = { [weak self] in
            self?.claudeStatusLabel() ?? "checking…"
        }
        MainWindowController.shared.currentQuota = { [weak self] in self?.lastQuota }
        if UserDefaults.standard.bool(forKey: "overlayHidden") {
            island.setVisible(false)
        }

        monitor.start()
        usage.start()
        hooks.start()
        quota.start()
        rotation.start()

        // LaunchAgent startuje s --agent (bez okna); ruční spuštění okno ukáže.
        if !CommandLine.arguments.contains("--agent") {
            MainWindowController.shared.present()
        }
    }

    /// Klik na appku ve Finderu/Docku, když už běží → hlavní okno.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindowController.shared.present()
        return false
    }

    /// Stav účtu Claude pro nastavení. Prošlý půjčený token Claude Code se nevydává
    /// za „signed in" — řádek pak nabídne vlastní login, jehož token appka obnovuje sama.
    private func claudeStatusLabel() -> String {
        switch quotaFetchState {
        case .ok: return "signed in"
        case .stale: return "Claude Code token expired"
        case .signedOut: return "not signed in"
        default: return "checking…"
        }
    }

    /// Debug/introspekce: aktuální stav sessions v ~/.claude/vibe-state.json
    private static func dumpState(_ sessions: [AgentSession], quota: QuotaStatus?) {
        let rows = sessions.map { s -> [String: Any] in
            [
                "id": s.id, "title": s.title, "project": s.project,
                "state": "\(s.state)", "model": s.model,
                "term": s.termProgram ?? "", "last": s.lastActivity.description,
            ]
        }
        var top: [String: Any] = ["sessions": rows]
        if let quota {
            top["quota"] = [
                "fiveHourPct": quota.fiveHour?.pct ?? -1,
                "sevenDayPct": quota.sevenDay?.pct ?? -1,
                "sevenDayFablePct": quota.sevenDayFable?.pct ?? -1,
                "fiveHourReset": quota.fiveHour?.resetsAt?.description ?? "",
                "sevenDayReset": quota.sevenDay?.resetsAt?.description ?? "",
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: NSString(string: "~/.claude/vibe-state.json").expandingTildeInPath))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

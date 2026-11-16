import AppKit

/// Rotace účtů: víc Claude účtů + Codex v pořadí podle priority. Když aktivní
/// Claude účet dojde (5h nebo týdenní limit nad prahem), appka přepne Claude Code
/// na další Claude účet v pořadí. Když dojdou všechny Claude účty, předá to Codexu
/// (upozornění, volitelně otevře Codex v Terminálu). Po resetu limitu se vrací zpět.
///
/// Jak přepnutí funguje: Claude Code drží login v Keychain položce
/// „Claude Code-credentials" a identitu účtu v ~/.claude.json (oauthAccount).
/// Každý účet v rotaci má vlastní Keychain slot „NotchOverlay-account-<id>".
/// Přepnutí = (1) aktuální, možná Claude Codem obnovené credentials uložit zpět
/// do slotu aktivního účtu, (2) credentials cílového účtu zapsat do položky
/// Claude Code, (3) prohodit oauthAccount v ~/.claude.json.
///
/// Refresh tokeny se rotují (každé použití starý zneplatní), proto platí:
///  - token AKTIVNÍHO účtu patří Claude Code — appka ho jen čte, nikdy neobnovuje,
///  - tokeny NEAKTIVNÍCH účtů patří appce — obnovuje je a nový refresh token
///    hned zapíše zpět do slotu.

// MARK: - Keychain

enum Keychain {
    private static func run(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (-1, "") }
        // číst před waitUntilExit — velký výstup by jinak zablokoval pipe
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func read(service: String) -> String? {
        let r = run(["find-generic-password", "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        let text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Atribut „acct" existující položky. Zápis s jiným acct by vytvořil druhou
    /// položku vedle původní — a Claude Code by dál četl tu starou.
    static func accountAttribute(service: String) -> String? {
        let r = run(["find-generic-password", "-s", service])
        guard r.status == 0 else { return nil }
        for line in r.out.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            guard let start = line.range(of: "<blob>=\"") else { continue }
            let rest = line[start.upperBound...]
            if let end = rest.lastIndex(of: "\"") { return String(rest[..<end]) }
        }
        return nil
    }

    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        run(["add-generic-password", "-U", "-a", account, "-s", service, "-w", value]).status == 0
    }

    static func delete(service: String) {
        _ = run(["delete-generic-password", "-s", service])
    }
}

// MARK: - Model + nastavení

struct ClaudeAccount: Codable, Equatable {
    var id: String
    var label: String
    var email: String?
    var accountUuid: String?
    /// oauthAccount blok z ~/.claude.json (JSON) — při přepnutí se vrací Claude Code.
    var oauthAccountJSON: String?

    var keychainService: String { "NotchOverlay-account-\(id)" }
    var orderKey: String { "claude:\(id)" }
}

enum RotationPrefs {
    private static var d: UserDefaults { .standard }
    static let codexKey = "codex"

    static var enabled: Bool {
        get { d.bool(forKey: "rotationEnabled") }
        set { d.set(newValue, forKey: "rotationEnabled") }
    }
    /// Práh využití (%) — od něj se účet bere jako vyčerpaný.
    static var threshold: Int {
        get { let v = d.integer(forKey: "rotationThreshold"); return v == 0 ? 95 : v }
        set { d.set(newValue, forKey: "rotationThreshold") }
    }
    /// Co udělat, když dojdou všechny Claude účty: "notify" / "open" (Codex v Terminálu).
    static var codexAction: String {
        get { d.string(forKey: "rotationCodexAction") ?? "notify" }
        set { d.set(newValue, forKey: "rotationCodexAction") }
    }
    static var activeId: String? {
        get { d.string(forKey: "rotationActiveId") }
        set { d.set(newValue, forKey: "rotationActiveId") }
    }
    static var accounts: [ClaudeAccount] {
        get {
            guard let data = d.data(forKey: "rotationAccounts"),
                  let list = try? JSONDecoder().decode([ClaudeAccount].self, from: data)
            else { return [] }
            return list
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "rotationAccounts") }
    }
    /// Pořadí priority: "claude:<id>" a "codex". Vždy obsahuje každý účet
    /// právě jednou a Codex (default na konci).
    static var order: [String] {
        get {
            let keys = accounts.map(\.orderKey)
            var o = (d.stringArray(forKey: "rotationOrder") ?? []).filter { keys.contains($0) || $0 == codexKey }
            var seen = Set<String>()
            o = o.filter { seen.insert($0).inserted }
            for k in keys where !o.contains(k) {
                // nový účet patří před Codex
                if let ci = o.firstIndex(of: codexKey) { o.insert(k, at: ci) } else { o.append(k) }
            }
            if !o.contains(codexKey) { o.append(codexKey) }
            return o
        }
        set { d.set(newValue, forKey: "rotationOrder") }
    }
}

// MARK: - Claude Code storage

enum ClaudeCodeLogin {
    static let service = "Claude Code-credentials"
    static var configPath: String { NSString(string: "~/.claude.json").expandingTildeInPath }

    static func readCreds() -> String? { Keychain.read(service: service) }

    static func writeCreds(_ raw: String) -> Bool {
        let acct = Keychain.accountAttribute(service: service) ?? NSUserName()
        return Keychain.write(service: service, account: acct, value: raw)
    }

    private static func readConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func readOAuthAccount() -> [String: Any]? {
        readConfig()?["oauthAccount"] as? [String: Any]
    }

    /// Přepíše jen klíč oauthAccount, zbytek configu zůstane.
    @discardableResult
    static func writeOAuthAccount(_ oa: [String: Any]) -> Bool {
        guard var cfg = readConfig() else { return false }
        cfg["oauthAccount"] = oa
        guard let data = try? JSONSerialization.data(
            withJSONObject: cfg, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)) != nil
    }
}

/// Rozparsované OAuth credentials ve tvaru Claude Code ({"claudeAiOauth": {...}}).
struct OAuthCreds {
    var raw: [String: Any]
    var oauth: [String: Any] { raw["claudeAiOauth"] as? [String: Any] ?? [:] }
    var access: String? { oauth["accessToken"] as? String }
    var refresh: String? { (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var expiresAt: Date? { (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }

    init?(_ text: String) {
        guard let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["claudeAiOauth"] is [String: Any]
        else { return nil }
        raw = obj
    }

    var json: String? {
        guard let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Jen login ({"claudeAiOauth": …}) — do slotu účtu. Ostatní klíče položky
    /// Claude Code (mcpOAuth = tokeny MCP serverů) nepatří účtu a kopírovat se nemají.
    var loginOnlyJSON: String? {
        guard let d = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Zachová ostatní pole (scopes, subscriptionType…), přepíše jen tokeny.
    mutating func update(access: String, refresh: String, expiresAt: Date) {
        var o = oauth
        o["accessToken"] = access
        o["refreshToken"] = refresh
        o["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        raw["claudeAiOauth"] = o
    }
}

// MARK: - Engine

final class AccountRotation {
    static let shared = AccountRotation()

    enum Health: Equatable {
        case unknown
        case ok(QuotaStatus, at: Date)
        /// Slot nemá použitelný login (refresh token neplatí) — přidat účet znovu.
        case needsLogin
        case error(String)
    }

    /// Kvóty aktivního účtu pro island/menu bar (když rotace řídí kvóty).
    var onActiveQuota: ((QuotaFetchState) -> Void)?
    /// Cokoli se změnilo (stav účtů, přepnutí) — UI se překreslí. Volá se na main.
    var onChange: (() -> Void)?
    /// Claude Code přešel na jiný účet (přepnutí appkou nebo ruční /login) — běžný
    /// fetcher kvót drží token předchozího účtu v cache a musí ho zahodit.
    var onLoginChange: (() -> Void)?
    private var loginResolved = false   // main
    /// Pracovní adresář poslední session — Codex se otevře tam.
    var latestCwd: (() -> String?)?

    private(set) var health: [String: Health] = [:]       // main
    private(set) var activeId: String?                    // main
    private(set) var currentTarget: String?               // main, "claude:<id>" / "codex" / nil = vše došlo
    private(set) var lastEvent: String?                   // main, poslední přepnutí pro UI
    /// Účet, ke kterému je Claude Code přihlášený (z ~/.claude.json), obnovuje pollAll.
    /// Island ho čte každou sekundu při hoveru — config má stovky KB, proto cache.
    private(set) var currentLogin: (email: String?, uuid: String?) = (nil, nil)   // main
    /// Čte i quota queue (isPaused) — Bool, benigní race.
    private(set) var drivesQuota = false

    private let queue = DispatchQueue(label: "account-rotation", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval = 300
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private var switching = false   // main
    private var notifiedAllOut = false

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: interval)
        t.setEventHandler { [weak self] in self?.pollAll() }
        t.resume()
        timer = t
        updateDrivesQuota()
    }

    func refreshNow() { queue.async { self.pollAll() } }

    func settingsChanged() {
        updateDrivesQuota()
        decide()
        onChange?()
    }

    private func updateDrivesQuota() {
        drivesQuota = RotationPrefs.enabled && activeId != nil
    }

    // MARK: Účty

    /// Uloží login, ke kterému je Claude Code právě přihlášený, jako účet v rotaci.
    /// Když už v seznamu je (stejné accountUuid), jen obnoví jeho uložený login.
    func addCurrentLogin(completion: @escaping (String) -> Void) {
        queue.async {
            let msg = self.captureCurrentLogin()
            self.pollAll()
            DispatchQueue.main.async { completion(msg) }
        }
    }

    private func captureCurrentLogin() -> String {
        guard let full = ClaudeCodeLogin.readCreds(), let creds = OAuthCreds(full),
              let raw = creds.loginOnlyJSON else {
            return "Claude Code isn't logged in. Run /login in Claude Code first."
        }
        let oa = ClaudeCodeLogin.readOAuthAccount()
        let uuid = oa?["accountUuid"] as? String
        let email = oa?["emailAddress"] as? String
        let oaJSON = oa.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }

        var accounts = RotationPrefs.accounts
        if let uuid, let i = accounts.firstIndex(where: { $0.accountUuid == uuid }) {
            Keychain.write(service: accounts[i].keychainService, account: "notch", value: raw)
            accounts[i].oauthAccountJSON = oaJSON ?? accounts[i].oauthAccountJSON
            RotationPrefs.accounts = accounts
            RotationPrefs.activeId = accounts[i].id
            return "\(accounts[i].label) was already added, its login is refreshed."
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let acct = ClaudeAccount(id: id, label: email ?? "Claude \(accounts.count + 1)",
                                 email: email, accountUuid: uuid, oauthAccountJSON: oaJSON)
        guard Keychain.write(service: acct.keychainService, account: "notch", value: raw) else {
            return "Couldn't save the login to Keychain."
        }
        accounts.append(acct)
        RotationPrefs.accounts = accounts
        RotationPrefs.activeId = id
        return "Added \(acct.label). To add another account, run /login in Claude Code with it and add it here again."
    }

    func remove(id: String) {
        queue.async {
            var accounts = RotationPrefs.accounts
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
            // Keychain slot smazat; login v Claude Code zůstává netknutý.
            Keychain.delete(service: accounts[i].keychainService)
            accounts.remove(at: i)
            RotationPrefs.accounts = accounts
            if RotationPrefs.activeId == id { RotationPrefs.activeId = nil }
            DispatchQueue.main.async {
                self.health[id] = nil
                if self.activeId == id { self.activeId = nil }
                self.settingsChanged()
            }
        }
    }

    func move(_ key: String, by delta: Int) {
        var o = RotationPrefs.order
        guard let i = o.firstIndex(of: key) else { return }
        let j = i + delta
        guard j >= 0, j < o.count else { return }
        o.swapAt(i, j)
        RotationPrefs.order = o
        settingsChanged()
    }

    /// Ruční přepnutí (tlačítko „Use").
    func use(id: String) {
        guard let acct = RotationPrefs.accounts.first(where: { $0.id == id }) else { return }
        performSwitch(to: acct, reason: "switched manually")
    }

    // MARK: Polling

    private func pollAll() {
        let accounts = RotationPrefs.accounts
        let active = resolveActiveId(accounts)
        let oa = ClaudeCodeLogin.readOAuthAccount()
        let login = (email: oa?["emailAddress"] as? String, uuid: oa?["accountUuid"] as? String)
        var fresh: [String: Health] = [:]
        for a in accounts {
            fresh[a.id] = poll(a, isActive: a.id == active)
        }
        DispatchQueue.main.async {
            for (id, h) in fresh {
                // přechodná chyba / neznámo nepřepisuje poslední dobrá data
                if case .ok = self.health[id] ?? .unknown, !Self.isDefinitive(h) { continue }
                self.health[id] = h
            }
            self.activeId = active
            let loginChanged = self.loginResolved && login.uuid != self.currentLogin.uuid
            self.loginResolved = true
            self.currentLogin = login
            if loginChanged { self.onLoginChange?() }
            self.updateDrivesQuota()
            self.publishActive()
            self.decide()
            self.onChange?()
        }
    }

    private static func isDefinitive(_ h: Health) -> Bool {
        switch h {
        case .ok, .needsLogin: return true
        case .unknown, .error: return false
        }
    }

    /// Který účet z rotace má teď Claude Code. Rozhoduje accountUuid v ~/.claude.json —
    /// když se uživatel ručně přihlásil jinam, nesmíme jeho login uložit pod cizí účet.
    private func resolveActiveId(_ accounts: [ClaudeAccount]) -> String? {
        if let uuid = ClaudeCodeLogin.readOAuthAccount()?["accountUuid"] as? String {
            let match = accounts.first { $0.accountUuid == uuid }?.id
            if match != RotationPrefs.activeId { RotationPrefs.activeId = match }
            return match
        }
        let stored = RotationPrefs.activeId
        return accounts.contains { $0.id == stored } ? stored : nil
    }

    private func poll(_ a: ClaudeAccount, isActive: Bool) -> Health {
        let token: String
        if isActive {
            // Token Claude Code jen čteme. Prošlý = Claude Code ho obnoví při dalším použití.
            guard let raw = ClaudeCodeLogin.readCreds(), let c = OAuthCreds(raw), let t = c.access
            else { return .unknown }
            if let e = c.expiresAt, e.timeIntervalSinceNow < 60 { return .unknown }
            token = t
        } else {
            switch ownedToken(a) {
            case .some(.some(let t)): token = t
            case .some(.none): return .needsLogin
            case .none: return .error("refresh failed")
            }
        }
        return fetchUsage(token: token)
    }

    /// Platný access token neaktivního účtu (obnoví ho, když prošel).
    /// nil = síťová chyba, .some(nil) = login je mrtvý.
    private func ownedToken(_ a: ClaudeAccount) -> String?? {
        guard let raw = Keychain.read(service: a.keychainService), var c = OAuthCreds(raw),
              let access = c.access
        else { return .some(nil) }
        if let e = c.expiresAt, e.timeIntervalSinceNow > 60 { return .some(access) }
        guard let refresh = c.refresh else { return .some(nil) }
        switch refreshToken(refresh) {
        case .ok(let newAccess, let newRefresh, let exp):
            c.update(access: newAccess, refresh: newRefresh, expiresAt: exp)
            if let json = c.json { Keychain.write(service: a.keychainService, account: "notch", value: json) }
            return .some(newAccess)
        case .invalid: return .some(nil)
        case .failed: return nil
        }
    }

    private enum RefreshResult { case ok(String, String, Date), invalid, failed }

    private func refreshToken(_ refresh: String) -> RefreshResult {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId,
        ])
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var result = RefreshResult.failed
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            if http.statusCode == 400 || http.statusCode == 401 { result = .invalid; return }
            guard http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String
            else { return }
            let ttl = (obj["expires_in"] as? Double) ?? 3600
            let rotated = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refresh
            result = .ok(access, rotated, Date().addingTimeInterval(ttl))
        }.resume()
        sem.wait()
        return result
    }

    private func fetchUsage(token: String) -> Health {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var h = Health.error("no response")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { h = .error(err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            switch http.statusCode {
            case 200:
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let q = QuotaFetcher.parseUsage(obj) {
                    h = .ok(q, at: Date())
                } else { h = .error("unknown response") }
            case 401: h = .needsLogin
            case 429: h = .error("rate limited")
            default: h = .error("HTTP \(http.statusCode)")
            }
        }.resume()
        sem.wait()
        return h
    }

    private func publishActive() {
        guard drivesQuota, let id = activeId else { return }
        switch health[id] ?? .unknown {
        case .ok(let q, _): onActiveQuota?(.ok(q))
        case .needsLogin: onActiveQuota?(.signedOut)
        default: break
        }
    }

    // MARK: Rozhodování

    /// Vyčerpaný = 5h nebo týdenní okno nad prahem a reset ještě nepřišel.
    static func exhaustion(_ q: QuotaStatus, threshold: Int) -> (out: Bool, until: Date?) {
        var until: Date?
        var out = false
        for w in [q.fiveHour, q.sevenDay].compactMap({ $0 }) where w.pct >= threshold {
            if let r = w.resetsAt, r <= Date() { continue }  // reset už proběhl, data jsou stará
            out = true
            if let r = w.resetsAt { until = max(until ?? r, r) }
        }
        return (out, until)
    }

    func claudeAvailable(_ id: String) -> Bool {
        switch health[id] ?? .unknown {
        case .ok(let q, _): return !Self.exhaustion(q, threshold: RotationPrefs.threshold).out
        // Aktivní účet necháváme i při prošlém tokenu nebo přechodné chybě (429, výpadek
        // sítě) — jinak by jediný neúspěšný dotaz po startu přepnul zdravý účet.
        // Neověřený nebo nedostupný neaktivní účet nevolíme.
        case .unknown, .error: return id == activeId
        case .needsLogin: return false
        }
    }

    func codexAvailable() -> Bool {
        guard Providers.codex().signedIn else { return false }
        if case .window(let pct, let resets) = CodexQuota.latest(), pct >= RotationPrefs.threshold {
            if let r = resets, r <= Date() { return true }
            return false
        }
        return true
    }

    private func decide() {
        guard RotationPrefs.enabled, !switching, !RotationPrefs.accounts.isEmpty else { return }
        let accounts = RotationPrefs.accounts
        var target: String?
        for key in RotationPrefs.order {
            if key == RotationPrefs.codexKey {
                if codexAvailable() { target = key; break }
                continue
            }
            let id = String(key.dropFirst("claude:".count))
            if claudeAvailable(id) { target = key; break }
        }
        let previous = currentTarget
        currentTarget = target

        guard let target else {
            if !notifiedAllOut {
                notifiedAllOut = true
                notify("All accounts are out", body: "Claude and Codex limits are used up. Next reset: \(nextResetText()).")
                Sounds.shared.denied()
            }
            return
        }
        notifiedAllOut = false

        if target == RotationPrefs.codexKey {
            guard previous != target else { return }
            lastEvent = "Claude accounts out → Codex"
            Sounds.shared.permission()
            if RotationPrefs.codexAction == "open" {
                openCodex()
                notify("Switched to Codex", body: "All Claude accounts hit their limit. Opened Codex in Terminal.")
            } else {
                notify("Switch to Codex", body: "All Claude accounts hit their limit. Codex still has room.")
            }
            return
        }
        let id = String(target.dropFirst("claude:".count))
        if id != activeId, let acct = accounts.first(where: { $0.id == id }) {
            let reason = previous == RotationPrefs.codexKey ? "Claude limit reset" : "previous account hit its limit"
            performSwitch(to: acct, reason: reason)
        } else if previous == RotationPrefs.codexKey {
            // Claude Code už je na správném účtu, jen se mu resetoval limit.
            let name = label(for: id) ?? "Claude"
            lastEvent = "Back on \(name) (Claude limit reset)"
            Sounds.shared.sessionStart()
            notify("Back to Claude", body: "\(name) has room again. Claude Code is ready.")
        }
    }

    private func performSwitch(to target: ClaudeAccount, reason: String) {
        guard !switching else { return }
        switching = true
        queue.async {
            let error = self.switchClaudeCode(to: target)
            self.pollAll()
            DispatchQueue.main.async {
                self.switching = false
                if let error {
                    self.lastEvent = "Switch to \(target.label) failed: \(error)"
                    self.notify("Account switch failed", body: error)
                    // účet vyřadit, ať decide() nezkouší pořád dokola to samé
                    self.health[target.id] = .needsLogin
                } else {
                    self.lastEvent = "Now on \(target.label) (\(reason))"
                    Sounds.shared.sessionStart()
                    self.notify("Claude → \(target.label)",
                                body: "\(reason.prefix(1).uppercased() + reason.dropFirst()). New Claude Code sessions use this account.")
                }
                self.decide()
                self.onChange?()
            }
        }
    }

    /// Běží na `queue`. Vrací nil při úspěchu.
    private func switchClaudeCode(to target: ClaudeAccount) -> String? {
        var accounts = RotationPrefs.accounts
        let active = resolveActiveId(accounts)
        if active == target.id { return nil }

        if let active, let i = accounts.firstIndex(where: { $0.id == active }) {
            // Claude Code mohl token mezitím obnovit — rotovaný refresh token uložit zpět.
            if let current = ClaudeCodeLogin.readCreds(), let login = OAuthCreds(current)?.loginOnlyJSON {
                Keychain.write(service: accounts[i].keychainService, account: "notch", value: login)
            }
            if let oa = ClaudeCodeLogin.readOAuthAccount(),
               let d = try? JSONSerialization.data(withJSONObject: oa) {
                accounts[i].oauthAccountJSON = String(data: d, encoding: .utf8)
            }
            RotationPrefs.accounts = accounts
        } else if ClaudeCodeLogin.readCreds() != nil {
            // Claude Code je přihlášený k účtu mimo rotaci — nejdřív ho uložit, ať o něj nepřijdeme.
            _ = captureCurrentLogin()
        }

        // Cílový token obnovit předem — Claude Code ho dostane čerstvý a od teď je jeho.
        guard case .some(.some(_)) = ownedToken(target) else {
            return "the saved login for \(target.label) expired. Log in with it in Claude Code and add it again."
        }
        guard let raw = Keychain.read(service: target.keychainService) else {
            return "no saved login for \(target.label)"
        }
        guard let targetCreds = OAuthCreds(raw) else { return "the saved login for \(target.label) is damaged" }
        var merged: [String: Any] = [:]
        if let cur = ClaudeCodeLogin.readCreds(), let d = cur.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { merged = obj }
        merged["claudeAiOauth"] = targetCreds.oauth
        guard let md = try? JSONSerialization.data(withJSONObject: merged),
              let mergedJSON = String(data: md, encoding: .utf8),
              ClaudeCodeLogin.writeCreds(mergedJSON)
        else { return "couldn't write to the Claude Code Keychain item" }
        if let json = target.oauthAccountJSON, let d = json.data(using: .utf8),
           let oa = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ClaudeCodeLogin.writeOAuthAccount(oa)
        }
        RotationPrefs.activeId = target.id
        return nil
    }

    // MARK: Codex + upozornění

    func openCodex() {
        var cmd = "codex"
        if let cwd = latestCwd?(), FileManager.default.fileExists(atPath: cwd) {
            cmd = "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && codex"
        }
        Providers.openTerminal(command: cmd)
    }

    private func nextResetText() -> String {
        var dates: [Date] = []
        for h in health.values {
            if case .ok(let q, _) = h, let u = Self.exhaustion(q, threshold: RotationPrefs.threshold).until { dates.append(u) }
        }
        if case .window(_, let r?) = CodexQuota.latest() { dates.append(r) }
        guard let next = dates.filter({ $0 > Date() }).min() else { return "unknown" }
        return "in \(remainingString(until: next))"
    }

    /// Systémová notifikace přes osascript — funguje bez entitlementů a podpisu.
    private func notify(_ title: String, body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"NotchOverlay\" subtitle \"\(esc(title))\""]
        try? p.run()
    }

    // MARK: Texty pro UI

    func label(for id: String) -> String? {
        RotationPrefs.accounts.first { $0.id == id }?.label
    }

    func statusText(for id: String) -> (text: String, warning: Bool) {
        let t = RotationPrefs.threshold
        switch health[id] ?? .unknown {
        case .ok(let q, _):
            var parts: [String] = []
            if let f = q.fiveHour { parts.append("5h \(f.pct)%") }
            if let w = q.sevenDay { parts.append("week \(w.pct)%") }
            let ex = Self.exhaustion(q, threshold: t)
            if ex.out { parts.append(ex.until.map { "out, resets in \(remainingString(until: $0))" } ?? "out") }
            return (parts.joined(separator: " · "), ex.out)
        case .needsLogin:
            return ("login expired - /login with it in Claude Code, then Add again", true)
        case .error(let e):
            return ("can't check: \(e)", true)
        case .unknown:
            return (id == activeId ? "waiting for Claude Code to refresh its token" : "checking…", false)
        }
    }

    func codexStatusText() -> (text: String, warning: Bool) {
        let p = Providers.codex()
        guard p.installed else { return ("not installed", true) }
        guard p.signedIn else { return ("not signed in - run codex login", true) }
        switch CodexQuota.latest() {
        case .window(let pct, let r):
            var s = "5h \(pct)%"
            let out = !codexAvailable()
            if out { s += r.map { " · out, resets in \(remainingString(until: $0))" } ?? " · out" }
            return (s, out)
        case .planOnly(let plan): return ("\(plan) plan · no limit windows", false)
        case .apiKey: return ("API key · pay per token", false)
        case nil: return ("signed in · no usage data yet", false)
        }
    }

    /// Jedna řádka do islandu: „▸ work 40% · personal out 2h · codex 12%".
    func summaryLine() -> String {
        guard !RotationPrefs.accounts.isEmpty else { return "rotation: no accounts (right-click → Rotation)" }
        var parts: [String] = []
        for key in RotationPrefs.order {
            let isTarget = key == currentTarget
            let mark = isTarget ? "▸" : ""
            if key == RotationPrefs.codexKey {
                var s = "\(mark)codex"
                if case .window(let pct, _) = CodexQuota.latest() { s += " \(pct)%" }
                parts.append(s)
                continue
            }
            let id = String(key.dropFirst("claude:".count))
            let name = shortName(label(for: id) ?? id)
            var s = "\(mark)\(name)"
            if case .ok(let q, _) = health[id] ?? .unknown {
                let ex = Self.exhaustion(q, threshold: RotationPrefs.threshold)
                if ex.out { s += ex.until.map { " out \(remainingString(until: $0))" } ?? " out" }
                else if let f = q.fiveHour { s += " \(f.pct)%" }
            }
            parts.append(s)
        }
        var line = parts.joined(separator: " · ")
        if !RotationPrefs.enabled { line = "rotation off · " + line }
        return line
    }

    /// E-mail → jen část před @, ať se řádka vejde.
    private func shortName(_ label: String) -> String {
        let base = label.split(separator: "@").first.map(String.init) ?? label
        return base.count > 12 ? String(base.prefix(11)) + "…" : base
    }
}

// MARK: - Přehled účtů pro nastavení

extension AccountRotation {
    /// Jeden přihlášený Claude účet v nastavení: e-mail, jestli na něm běží Claude Code,
    /// a využití aktuálního 5h okna.
    struct UsageRow {
        let label: String
        let active: Bool
        let text: String
        let warning: Bool
        let tooltip: String
        var fivePct: Int? = nil
        /// Všechna okna účtu (5h, týden, Fable…) pro detailní přehled v nastavení.
        var quota: QuotaStatus? = nil
    }

    /// Účty z rotace v pořadí priority. Když je Claude Code přihlášený k účtu mimo rotaci,
    /// přidá i ten — s kvótami z běžného fetcheru (`current`).
    func usageRows(current: QuotaStatus?, all: Bool = Display.showAllAccounts) -> [UsageRow] {
        let rows = allUsageRows(current: current)
        return all ? rows : Array(rows.filter(\.active).prefix(1))
    }

    private func allUsageRows(current: QuotaStatus?) -> [UsageRow] {
        let accounts = RotationPrefs.accounts
        var rows: [UsageRow] = []
        for key in RotationPrefs.order where key != RotationPrefs.codexKey {
            let id = String(key.dropFirst("claude:".count))
            guard let a = accounts.first(where: { $0.id == id }) else { continue }
            let active = id == activeId
            // aktivní účet: stejná čísla jako hlavička islandu (běžný fetcher nebo rotace)
            if active, let current {
                rows.append(Self.usageRow(label: a.label, active: true, quota: current))
                continue
            }
            switch health[id] ?? .unknown {
            case .ok(let q, _):
                rows.append(Self.usageRow(label: a.label, active: active, quota: q))
            case .needsLogin:
                rows.append(UsageRow(label: a.label, active: active, text: "login expired", warning: true,
                                     tooltip: "Log in with this account in Claude Code (/login, not /logout), then add it again in Rotation."))
            case .error(let e):
                rows.append(UsageRow(label: a.label, active: active, text: "can't check", warning: true,
                                     tooltip: "Couldn't load usage: \(e)"))
            case .unknown:
                rows.append(UsageRow(label: a.label, active: active, text: "checking…", warning: false,
                                     tooltip: active ? "Waiting for Claude Code to refresh its token." : "Loading usage…"))
            }
        }
        // Claude Code na účtu, který v rotaci není.
        if let email = currentLogin.email {
            let uuid = currentLogin.uuid
            if !accounts.contains(where: { $0.accountUuid != nil && $0.accountUuid == uuid }) {
                if let current {
                    rows.insert(Self.usageRow(label: email, active: true, quota: current), at: 0)
                } else {
                    rows.insert(UsageRow(label: email, active: true, text: "checking…", warning: false,
                                         tooltip: "Loading usage…"), at: 0)
                }
            }
        }
        return rows
    }

    /// „5h 12% · resets 3h 40m". Oranžově, když je účet nad prahem rotace
    /// (5h nebo týden); týden se do textu přidá, jen když je on ten limit.
    private static func usageRow(label: String, active: Bool, quota q: QuotaStatus) -> UsageRow {
        let threshold = RotationPrefs.threshold
        var text: String
        if let f = q.fiveHour {
            if let r = f.resetsAt, r <= Date() {
                text = "5h new window"
            } else {
                text = "5h \(f.pct)%"
                if let r = f.resetsAt { text += " · resets \(remainingString(until: r))" }
            }
        } else {
            text = "5h no data"
        }
        if let w = q.sevenDay, w.pct >= threshold, (w.resetsAt ?? .distantFuture) > Date() {
            text = (q.fiveHour.map { "5h \($0.pct)%" } ?? "5h –") + " · week \(w.pct)%"
        }
        var tip: [String] = []
        if let f = q.fiveHour {
            tip.append("5-hour window: \(f.pct)%" + (f.resetsAt.map { ", resets in \(remainingString(until: $0))" } ?? ""))
        }
        if let w = q.sevenDay {
            tip.append("Weekly: \(w.pct)%" + (w.resetsAt.map { ", resets in \(remainingString(until: $0))" } ?? ""))
        }
        if active { tip.append("Claude Code is logged in with this account.") }
        return UsageRow(label: label, active: active, text: text,
                        warning: exhaustion(q, threshold: threshold).out,
                        tooltip: tip.joined(separator: "\n"),
                        fivePct: q.fiveHour.flatMap { f in (f.resetsAt ?? .distantFuture) > Date() ? f.pct : 0 },
                        quota: q)
    }

    private static var lastOnDemandRefresh = Date.distantPast

    /// Otevření nastavení: obnovit kvóty, když jsou starší než `maxAge`.
    /// Nejvýš jednou za minutu — usage API při častém dotazování vrací 429.
    func refreshIfStale(maxAge: TimeInterval = 120) {
        let accounts = RotationPrefs.accounts
        guard !accounts.isEmpty, Date().timeIntervalSince(Self.lastOnDemandRefresh) > 60 else { return }
        let stale = accounts.contains { a in
            if case .ok(_, let at) = health[a.id] ?? .unknown { return Date().timeIntervalSince(at) > maxAge }
            return true
        }
        guard stale else { return }
        Self.lastOnDemandRefresh = Date()
        refreshNow()
    }
}

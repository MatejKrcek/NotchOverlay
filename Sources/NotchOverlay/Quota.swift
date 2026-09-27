import Foundation

struct QuotaWindow: Equatable {
    var pct: Int
    var resetsAt: Date?
}

struct QuotaStatus: Equatable {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var sevenDayOpus: QuotaWindow?
    /// Paid: limit Fable 5 (Mythos tier), pokud ho usage API vrací.
    var sevenDayFable: QuotaWindow?
}

enum QuotaFetchState: Equatable {
    case starting
    case ok(QuotaStatus)
    case rateLimited(until: Date)
    case signedOut
    /// Půjčený token Claude Code prošel a appka ho sama neobnovuje (viz QuotaFetcher).
    /// UI drží poslední hodnoty, ale musí je označit jako neaktuální. `since` = kdy
    /// jsme to zjistili poprvé (drží se, ať se UI zbytečně nepřekresluje).
    case stale(since: Date)
}

/// Reálný stav rate limitů z api.anthropic.com/api/oauth/usage.
/// Credentials bere z Keychain: nejdřív vlastní („NotchOverlay-credentials",
/// vytvoří je in-app login), jinak od Claude Code („Claude Code-credentials").
///
/// Refresh tokeny se ROTUJÍ: každé použití vrátí nový a ten starý zneplatní.
/// Proto:
///  - token Claude Code se jen čte — NIKDY se přes jeho refresh token
///    neobnovuje. Kdybychom to udělali, Claude Code by měl v Keychain mrtvý
///    refresh token a při příští obnově (8 h) by uživatele odhlásil („/login"
///    dvakrát denně). Když je prošlý, počkáme, až si ho Claude Code obnoví sám.
///  - vlastní credentials obnovujeme, ale nový refresh token + expiraci hned
///    zapíšeme zpět do Keychain, ať další refresh po 8 h neselže.
final class QuotaFetcher {
    var onState: ((QuotaFetchState) -> Void)?

    private let queue = DispatchQueue(label: "quota-fetch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let debugPath = NSString(string: "~/.claude/vibe-quota-debug.txt").expandingTildeInPath

    /// Veřejné client_id OAuth klienta Claude Code — potřebné pro refresh flow.
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private var cachedToken: String?
    private var cachedExpiry: Date?

    /// Kvóty se mění pomalu — 5min interval, ať nedráždíme rate limit endpointu.
    private let interval: TimeInterval = 300
    /// Když půjčený token Claude Code prošel, nečekáme 5 min — Keychain je lokální,
    /// tak ho kontrolujeme každých 30 s, ať po obnově dohoníme stav rychle.
    private let staleInterval: TimeInterval = 30
    private var backoffUntil: Date = .distantPast
    private var staleSince: Date?

    private static let ownService = "NotchOverlay-credentials"
    private static let claudeCodeService = "Claude Code-credentials"
    private let keychainServices = [ownService, claudeCodeService]

    private enum TokenLookup {
        case token(String)
        /// Žádné credentials (ani vlastní, ani Claude Code) / explicitní odhlášení.
        case none
        /// Půjčený token Claude Code je prošlý — neobnovujeme ho, čekáme na Claude Code.
        case borrowedExpired
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: interval)
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume()
        timer = t
    }

    /// Po dokončení in-app loginu: zahodit cache a hned zkusit fetch.
    func credentialsChanged() {
        queue.async {
            self.cachedToken = nil
            self.cachedExpiry = nil
            self.backoffUntil = .distantPast
            self.fetch()
        }
    }

    private func push(_ state: QuotaFetchState) {
        DispatchQueue.main.async { self.onState?(state) }
    }

    private func fetch() {
        guard Date() >= backoffUntil else {
            push(.rateLimited(until: backoffUntil))
            return
        }
        let token: String
        switch currentToken() {
        case .token(let t):
            token = t
        case .none:
            debug("keychain: žádné credentials")
            setStale(false)
            push(.signedOut)
            return
        case .borrowedExpired:
            // UI si drží poslední hodnotu, ale označí ji jako stale; Claude Code si
            // token obnoví při dalším použití — do té doby čteme Keychain po 30 s.
            if staleSince == nil {
                debug("keychain: token Claude Code prošlý — čekám, až si ho Claude Code obnoví")
            }
            setStale(true)
            push(.stale(since: staleSince ?? Date()))
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result: QuotaStatus?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { self.debug("network: \(err.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 { self.cachedToken = nil; self.cachedExpiry = nil }
                if http.statusCode == 429 {
                    let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 600
                    self.backoffUntil = Date().addingTimeInterval(retry)
                    self.debug("http 429 — backoff \(Int(retry)) s")
                    self.push(.rateLimited(until: self.backoffUntil))
                } else {
                    self.debug("http \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                }
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.debug("parse: není JSON objekt")
                return
            }
            var q = QuotaStatus()
            q.fiveHour = Self.window(in: obj, keys: ["five_hour", "5h", "session"])
            q.sevenDay = Self.window(in: obj, keys: ["seven_day", "7d", "week", "weekly"])
            q.sevenDayOpus = Self.window(in: obj, keys: ["seven_day_opus", "seven_day_sonnet"])
            q.sevenDayFable = Self.window(in: obj, keys: ["seven_day_fable", "seven_day_mythos", "fable_weekly", "fable"])
                ?? Self.scopedLimit(in: obj, modelName: "fable")
            if q.fiveHour != nil || q.sevenDay != nil { result = q }
            else { self.debug("v odpovědi nejsou známá okna; dump: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")") }
        }.resume()
        sem.wait()
        // Jen úspěch přepisuje data — po přechodné chybě si UI drží poslední hodnotu.
        if let result {
            if staleSince != nil { debug("keychain: token obnoven, kvóty zase aktuální") }
            setStale(false)
            push(.ok(result))
        }
    }

    /// Přepne interval timeru: 30 s dokud čekáme na obnovu půjčeného tokenu,
    /// jinak standardních 5 min. Volat jen z `queue`.
    private func setStale(_ stale: Bool) {
        if stale {
            guard staleSince == nil else { return }
            staleSince = Date()
            timer?.schedule(deadline: .now() + staleInterval, repeating: staleInterval)
        } else {
            guard staleSince != nil else { return }
            staleSince = nil
            timer?.schedule(deadline: .now() + interval, repeating: interval)
        }
    }

    /// Model-scoped limit z pole `limits` (weekly_scoped se scope.model
    /// .display_name == modelName) — takhle API vrací limit Fable 5.
    private static func scopedLimit(in obj: [String: Any], modelName: String) -> QuotaWindow? {
        guard let limits = obj["limits"] as? [[String: Any]] else { return nil }
        for l in limits {
            guard let scope = l["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String,
                  name.lowercased().contains(modelName.lowercased())
            else { continue }
            guard let raw = (l["percent"] as? Double) ?? (l["percent"] as? Int).map(Double.init)
            else { continue }
            let pct = max(0, min(100, Int(raw.rounded())))
            var resets: Date?
            if let s = l["resets_at"] as? String { resets = parseISO(s) }
            return QuotaWindow(pct: pct, resetsAt: resets)
        }
        return nil
    }

    /// Najde okno kvóty pod některým z klíčů a vytáhne utilization (0–100) + reset.
    private static func window(in obj: [String: Any], keys: [String]) -> QuotaWindow? {
        for key in keys {
            guard let w = obj[key] as? [String: Any] else { continue }
            let raw = (w["utilization"] as? Double)
                ?? (w["utilization"] as? Int).map(Double.init)
                ?? (w["used_pct"] as? Double)
            guard let raw else { continue }
            let pct = max(0, min(100, Int(raw.rounded())))
            var resets: Date?
            if let s = w["resets_at"] as? String { resets = parseISO(s) }
            else if let t = w["resets_at"] as? Double { resets = Date(timeIntervalSince1970: t) }
            return QuotaWindow(pct: pct, resetsAt: resets)
        }
        return nil
    }

    // MARK: - Tokeny

    private func currentToken() -> TokenLookup {
        // Uživatel se explicitně odhlásil — nepoužívat ani fallback credentials.
        guard !UserDefaults.standard.bool(forKey: "claudeSignedOut") else { return .none }
        if let t = cachedToken, let e = cachedExpiry, e.timeIntervalSinceNow > 60 { return .token(t) }
        guard let creds = readCredentials() else { return .none }
        if let exp = creds.expiresAt, exp.timeIntervalSinceNow > 60 {
            return .token(creds.access)
        }
        if creds.service == Self.claudeCodeService {
            // Cizí refresh token nepoužívat (rotace by odhlásila Claude Code).
            return creds.expiresAt == nil ? .token(creds.access) : .borrowedExpired
        }
        if let refresh = creds.refresh, !refresh.isEmpty, let fresh = refreshAccessToken(refresh) {
            return .token(fresh)
        }
        return .token(creds.access)  // poslední pokus — třeba ještě platí
    }

    private func readCredentials() -> (service: String, access: String, refresh: String?, expiresAt: Date?)? {
        for service in keychainServices {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", service, "-w"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if let d = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let oauth = obj["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String {
                var expires: Date?
                if let ms = oauth["expiresAt"] as? Double {
                    expires = Date(timeIntervalSince1970: ms / 1000)
                }
                return (service, token, oauth["refreshToken"] as? String, expires)
            }
            return (service, text, nil, nil)  // kdyby v Keychain byl token přímo
        }
        return nil
    }

    /// Zapíše obnovené vlastní credentials zpět do Keychain (stejný tvar jako
    /// Login.swift), aby rotovaný refresh token nezůstal jen v paměti.
    private func persistOwnCredentials(access: String, refresh: String, expiresAt: Date) {
        let creds: [String: Any] = ["claudeAiOauth": [
            "accessToken": access,
            "refreshToken": refresh,
            "expiresAt": expiresAt.timeIntervalSince1970 * 1000,
        ]]
        guard let json = try? JSONSerialization.data(withJSONObject: creds),
              let jsonStr = String(data: json, encoding: .utf8)
        else { debug("keychain: credentials nejdou serializovat"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U", "-a", "notch",
                       "-s", Self.ownService, "-w", jsonStr]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { debug("keychain: add-generic-password exit \(p.terminationStatus)") }
        } catch {
            debug("keychain: security nejde spustit: \(error.localizedDescription)")
        }
    }

    private func refreshAccessToken(_ refreshToken: String) -> String? {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var token: String?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { self.debug("refresh: \(err.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            guard http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String
            else {
                self.debug("refresh http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let ttl = (obj["expires_in"] as? Double) ?? 3600
            self.cachedToken = access
            self.cachedExpiry = Date().addingTimeInterval(ttl - 300)
            self.debug("refresh: nový access token, platí \(Int(ttl)) s")
            // Rotace: server vrátil nový refresh token a starý zneplatnil — uložit,
            // jinak by další refresh (po 8 h) selhal a overlay by se „odhlásil".
            let rotated = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
            self.persistOwnCredentials(access: access, refresh: rotated,
                                       expiresAt: Date().addingTimeInterval(ttl))
            token = access
        }.resume()
        sem.wait()
        return token
    }

    private func debug(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: debugPath) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(toFile: debugPath, atomically: true, encoding: .utf8)
        }
    }
}

import AppKit
import CryptoKit

/// „Sign in with Claude" — stejný OAuth PKCE flow jako Claude Code:
/// otevře prohlížeč s autorizací, uživatel vloží zpět kód (code#state),
/// appka ho vymění za tokeny a uloží do vlastní Keychain položky
/// „NotchOverlay-credentials". Overlay panel je non-activating, proto
/// login běží v normálním (aktivujícím) okně.
final class LoginController: NSObject {
    static let shared = LoginController()
    var onSuccess: (() -> Void)?

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private var verifier = ""
    private var stateParam = ""

    private var window: NSWindow?
    private var codeField: NSTextField?
    private var statusLabel: NSTextField?

    func present() {
        if window == nil { buildWindow() }
        // PKCE parametry se generují jen tady — „Open browser again" musí použít
        // stejný verifier, jinak kód z dříve otevřené autorizace nejde vyměnit.
        verifier = Self.base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        stateParam = Self.base64url(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        startAuth()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - OAuth

    private func startAuth() {
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectUri),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: stateParam),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
        setStatus("Browser opened — authorize and paste the code back here.", error: false)
    }

    @objc private func openBrowserAgain() { startAuth() }

    @objc private func finish() {
        let raw = (codeField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            setStatus("Paste the code first.", error: true)
            return
        }
        let parts = raw.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let state = parts.count > 1 ? parts[1] : stateParam
        setStatus("Exchanging code…", error: false)

        DispatchQueue.global().async {
            let failure = self.exchange(code: code, state: state)
            DispatchQueue.main.async {
                if let failure {
                    self.setStatus("Login failed — \(failure)", error: true)
                } else {
                    self.setStatus("Signed in ✓", error: false)
                    self.onSuccess?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.window?.orderOut(nil)
                    }
                }
            }
        }
    }

    /// Vymění kód za tokeny a uloží je do Keychain. Vrací nil při úspěchu,
    /// jinak krátkou hlášku pro UI; detail jde do ~/.claude/vibe-quota-debug.txt.
    private func exchange(code: String, state: String) -> String? {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": verifier,
        ])
        req.timeoutInterval = 20

        let sem = DispatchSemaphore(value: 0)
        var failure: String? = "no response from server"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                Self.log("token exchange network: \(err.localizedDescription)")
                failure = err.localizedDescription
                return
            }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard http.statusCode == 200 else {
                Self.log("token exchange http \(http.statusCode): \(body.prefix(300))")
                failure = http.statusCode == 429
                    ? "rate limited (429), wait a few minutes and try again"
                    : "HTTP \(http.statusCode) — open browser again for a fresh code"
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String
            else {
                Self.log("token exchange: unexpected 200 body: \(body.prefix(300))")
                failure = "unexpected server response"
                return
            }
            let expiresIn = (obj["expires_in"] as? Double) ?? 3600
            let creds: [String: Any] = ["claudeAiOauth": [
                "accessToken": access,
                "refreshToken": obj["refresh_token"] as? String ?? "",
                "expiresAt": (Date().timeIntervalSince1970 + expiresIn) * 1000,
            ]]
            guard let json = try? JSONSerialization.data(withJSONObject: creds),
                  let jsonStr = String(data: json, encoding: .utf8)
            else {
                failure = "could not serialize credentials"
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["add-generic-password", "-U", "-a", "notch",
                           "-s", "NotchOverlay-credentials", "-w", jsonStr]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run() } catch {
                Self.log("keychain: security nejde spustit: \(error.localizedDescription)")
                failure = "could not write to Keychain"
                return
            }
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                Self.log("login ok — credentials saved to Keychain")
                failure = nil
            } else {
                Self.log("keychain add-generic-password exit \(p.terminationStatus)")
                failure = "Keychain write failed (\(p.terminationStatus))"
            }
        }.resume()
        sem.wait()
        return failure
    }

    /// Stejný debug soubor jako QuotaFetcher — login chyby ať jsou vidět tam,
    /// kam UI hláška odkazuje.
    private static func log(_ msg: String) {
        let path = NSString(string: "~/.claude/vibe-quota-debug.txt").expandingTildeInPath
        let line = "\(Date()) login: \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - UI

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Sign in with Claude"
        w.isReleasedWhenClosed = false
        w.level = .floating
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))

        let info = NSTextField(wrappingLabelWithString:
            "1. Browser opens claude.ai — authorize the app.\n2. Copy the code shown after authorizing.\n3. Paste it below and hit Sign in.")
        info.font = .systemFont(ofSize: 12)
        info.frame = NSRect(x: 20, y: 130, width: 420, height: 58)
        v.addSubview(info)

        let field = NSTextField(frame: NSRect(x: 20, y: 96, width: 420, height: 24))
        field.placeholderString = "code#state"
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        v.addSubview(field)
        codeField = field

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 20, y: 66, width: 420, height: 18)
        v.addSubview(status)
        statusLabel = status

        let browser = NSButton(title: "Open browser again", target: self, action: #selector(openBrowserAgain))
        browser.bezelStyle = .rounded
        browser.frame = NSRect(x: 20, y: 20, width: 170, height: 32)
        v.addSubview(browser)

        let done = NSButton(title: "Sign in", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 340, y: 20, width: 100, height: 32)
        v.addSubview(done)

        w.contentView = v
        window = w
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = error ? .systemRed : .secondaryLabelColor
    }
}

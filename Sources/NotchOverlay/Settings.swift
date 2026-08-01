import Foundation

/// Paid: co se v islandu zobrazuje. Klíče jsou negované („hide…"),
/// aby default (chybějící klíč) znamenal zobrazit.
enum Display {
    static var showSessionTokens: Bool {
        get { !UserDefaults.standard.bool(forKey: "hideSessionTokens") }
        set { UserDefaults.standard.set(!newValue, forKey: "hideSessionTokens") }
    }
    static var showQuotaInBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "hideQuotaBar") }
        set { UserDefaults.standard.set(!newValue, forKey: "hideQuotaBar") }
    }
    /// Druhá řádka pod hlavičkou expandovaného panelu:
    /// "none" / "codex" (lokální session soubory) / "fable" (Fable 5 limit) / "gemini" (zatím nemá zdroj).
    static var headerSecondLine: String {
        get { UserDefaults.standard.string(forKey: "headerSecondLine") ?? "none" }
        set { UserDefaults.standard.set(newValue, forKey: "headerSecondLine") }
    }
    /// 5h session v pravé části menu baru:
    /// "off" / "pct" (využití, např. „5h 16%") / "reset" (čas resetu, např. „17:30").
    static var menuBarFiveHour: String {
        get {
            let v = UserDefaults.standard.string(forKey: "menuBarFiveHour") ?? "off"
            return v == "left" ? "pct" : v  // dřívější mód „zbývající čas" nahradila procenta
        }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarFiveHour") }
    }
    /// Poslední zvolený styl hodnoty ("pct"/"reset") — přežije vypnutí položky,
    /// aby zapnutí přepínačem vrátilo, co uživatel měl.
    static var menuBarFiveHourStyle: String {
        get { UserDefaults.standard.string(forKey: "menuBarFiveHourStyle") ?? "pct" }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarFiveHourStyle") }
    }
}

/// Paid: účty CLI agentů. Přihlášení deleguje na CLI (codex login, gemini) —
/// appka jen detekuje stav z jejich config souborů a otevře Terminál.
struct ProviderStatus {
    let name: String
    let installed: Bool
    let signedIn: Bool
    let loginCommand: String?

    var label: String {
        if !installed { return "not installed" }
        return signedIn ? "signed in" : "not signed in"
    }
}

enum Providers {
    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
    }

    /// Hledá binárku v obvyklých cestách — appka z launchd nemá login PATH.
    private static func binaryInstalled(_ name: String) -> Bool {
        ["~/.local/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "~/.npm-global/bin/"]
            .contains { exists($0 + name) }
    }

    static func codex() -> ProviderStatus {
        ProviderStatus(
            name: "Codex CLI",
            installed: binaryInstalled("codex") || exists("~/.codex"),
            signedIn: exists("~/.codex/auth.json"),
            loginCommand: "codex login"
        )
    }

    static func gemini() -> ProviderStatus {
        ProviderStatus(
            name: "Gemini CLI",
            installed: binaryInstalled("gemini") || exists("~/.gemini"),
            signedIn: exists("~/.gemini/oauth_creds.json"),
            loginCommand: "gemini"
        )
    }

    /// Codex logout = smazání auth.json (totéž co `codex logout`).
    static func signOutCodex() {
        try? FileManager.default.removeItem(
            atPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath)
    }

    /// Gemini logout = smazání oauth credentials.
    static func signOutGemini() {
        for f in ["~/.gemini/oauth_creds.json", "~/.gemini/google_accounts.json"] {
            try? FileManager.default.removeItem(atPath: NSString(string: f).expandingTildeInPath)
        }
    }

    /// Claude sign out: smaže vlastní credentials appky a nastaví flag,
    /// aby se nepoužil fallback na credentials Claude Code (ty nemažeme).
    static func signOutClaude() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", "NotchOverlay-credentials"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        UserDefaults.standard.set(true, forKey: "claudeSignedOut")
    }

    /// Otevře Terminál s login příkazem CLI (vyžaduje Automation oprávnění).
    static func openLogin(command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

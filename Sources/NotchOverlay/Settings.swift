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

    /// Otevře Terminál s login příkazem CLI (vyžaduje Automation oprávnění).
    static func openLogin(command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

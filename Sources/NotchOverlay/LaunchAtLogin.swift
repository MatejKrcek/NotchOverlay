import Foundation
import ServiceManagement

/// Start po přihlášení = LaunchAgent `~/Library/LaunchAgents/com.matejkrcek.notchoverlay.plist`,
/// stejný jako z install.sh (start s --agent bez okna, restart po pádu).
///
/// Přepínač mění jen soubor, nikdy launchctl: `bootout` by zabil appku, pokud ji spustil
/// launchd, a `bootstrap` by kvůli RunAtLoad hned pustil druhou instanci. Změna se projeví
/// při dalším přihlášení. Volba se ukládá i do defaults (`launchAtLogin`), aby ji
/// install.sh při aktualizaci nepřepsal.
enum LaunchAtLogin {
    static let label = "com.matejkrcek.notchoverlay"
    private static let prefKey = "launchAtLogin"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Agent půjde zapsat jen z pevně nainstalované appky — ne z dev binárky v bin/,
    /// z připojeného DMG ani z dočasné kopie, kterou macOS vytvoří u appky spuštěné
    /// z Downloads (App Translocation). Cesta v plistu by po přihlášení nevedla nikam.
    static var canManage: Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") && !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    private static var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    enum State {
        case on, off
        /// Uživatel položku vypnul v Nastavení systému → Obecné → Položky po přihlášení.
        /// Soubor existuje, ale launchd ho při přihlášení nespustí.
        case blockedBySystem
    }

    /// Skutečný stav (soubor + dotaz na systém, ~0,5 ms) — volat jednou na přestavbu okna.
    static var state: State {
        guard plistExists else { return .off }
        return SMAppService.statusForLegacyPlist(at: plistURL) == .requiresApproval ? .blockedBySystem : .on
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try writePlist()
        } else if plistExists {
            try FileManager.default.removeItem(at: plistURL)
        }
        UserDefaults.standard.set(on, forKey: prefKey)
    }

    /// Při startu: appka se přesunula a agent ukazuje na binárku, která už neexistuje →
    /// přepsat na aktuální cestu. Platný agent jiné kopie (např. testovací build) nechává být.
    static func repairPathIfNeeded() {
        guard canManage, plistExists,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let program = (plist["ProgramArguments"] as? [String])?.first,
              !FileManager.default.fileExists(atPath: program)
        else { return }
        try? writePlist()
    }

    private static func writePlist() throws {
        guard canManage, let exe = Bundle.main.executablePath else {
            throw NSError(domain: "LaunchAtLogin", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Move NotchOverlay to the Applications folder and open it from there.",
            ])
        }
        // Stejný obsah jako v install.sh.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--agent"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }
}

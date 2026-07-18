import AppKit

/// Skok do terminálu, kde session běží. TERM_PROGRAM známe z hook eventů;
/// bez něj aktivujeme první běžící známý terminál.
enum Jump {
    private static let bundleIds: [String: [String]] = [
        "iTerm.app": ["com.googlecode.iterm2"],
        "Apple_Terminal": ["com.apple.Terminal"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WarpTerminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "WezTerm": ["com.github.wez.wezterm"],
        "kitty": ["net.kovidgoyal.kitty"],
        "vscode": ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"], // VS Code, Cursor
        "Alacritty": ["org.alacritty"],
    ]

    private static let fallbackOrder = [
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
        "com.apple.Terminal", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    @discardableResult
    static func toTerminal(termProgram: String?) -> Bool {
        var candidates: [String] = []
        if let tp = termProgram, let ids = bundleIds[tp] { candidates = ids }
        candidates += fallbackOrder
        for id in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return true
            }
        }
        return false
    }

    /// Allow/Deny: aktivuje terminál a pošle klávesu do permission dialogu
    /// Claude Code ("1" = povolit, Esc = zamítnout). Vyžaduje oprávnění
    /// Automation/Accessibility; bez něj skončí jen u aktivace terminálu.
    static func answerPermission(termProgram: String?, allow: Bool) {
        toTerminal(termProgram: termProgram)
        let script = allow
            ? "tell application \"System Events\" to keystroke \"1\""
            : "tell application \"System Events\" to key code 53"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        }
    }
}

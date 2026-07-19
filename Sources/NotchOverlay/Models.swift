import Foundation

enum SessionState: Equatable {
    case working(String)     // aktivně pracuje (popis: "Bash", "přemýšlí…")
    case stalled(String)     // tool_use bez výsledku a nic se neděje — nejspíš čeká na permission
    case permission(String)  // potvrzeno hookem: čeká na povolení nástroje
    case question            // agent položil otázku / čeká na vstup
    case failed(String)      // chyba (API error apod.)
    case done                // dokončeno, čeká na tebe
    case idle

    var priority: Int {
        switch self {
        case .permission: return 0
        case .failed: return 1
        case .question: return 2
        case .stalled: return 3
        case .working: return 4
        case .done: return 5
        case .idle: return 6
        }
    }

    /// Stavy, kdy je potřeba zásah uživatele.
    var needsAttention: Bool { priority <= 3 }
}

struct AgentSession: Equatable {
    let id: String           // sessionId
    var title: String        // aiTitle nebo slug
    var project: String      // poslední složka cwd
    var branch: String?
    var model: String        // zkrácený název modelu
    var state: SessionState
    var lastActivity: Date
    var termProgram: String? // TERM_PROGRAM z hook eventu, pro jump
    var transcriptPath: String
}

struct UsageSummary: Equatable {
    var fiveHourOutputTokens: Int = 0
    var todayOutputTokens: Int = 0
    var todayCostUSD: Double = 0
    var fiveHourCostUSD: Double = 0
    /// Paid: output tokeny per session (klíč = cesta k transkriptu, okno 26 h).
    var perSessionOutput: [String: Int] = [:]
}

func shortModelName(_ model: String) -> String {
    if model.contains("fable") { return "fable" }
    if model.contains("opus") { return "opus" }
    if model.contains("sonnet") { return "sonnet" }
    if model.contains("haiku") { return "haiku" }
    return model
}

func shortTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
    default: return "\(n)"
    }
}

func elapsedString(since date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(s % 60)s" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

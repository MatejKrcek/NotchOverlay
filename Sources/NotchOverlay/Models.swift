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
    /// Odhad spendu (USD) per session — stejný klíč a okno jako perSessionOutput.
    var perSessionCost: [String: Double] = [:]
}

/// Sdílený odhad cen — jeden zdroj pravdy pro UsageStats i SpendStats.
enum Pricing {
    /// Hrubý odhad ceny za 1M tokenů (input, output, cache read).
    static func rates(for model: String) -> (inp: Double, out: Double, cache: Double) {
        if model.contains("haiku") { return (0.8, 4, 0.08) }
        if model.contains("sonnet") { return (3, 15, 0.3) }
        return (15, 75, 1.5)  // opus / fable
    }

    /// Odhad ceny v USD z rozpadu tokenů. input+cache_creation účtováno vstupní
    /// sazbou, output výstupní, cache_read cache sazbou.
    static func cost(input: Int, cacheCreation: Int, output: Int,
                     cacheRead: Int, model: String) -> Double {
        let p = rates(for: model)
        return Double(input + cacheCreation) / 1e6 * p.inp
             + Double(output) / 1e6 * p.out
             + Double(cacheRead) / 1e6 * p.cache
    }
}

/// Jedno spend okno: součet tokenů (in+cache_creation+out+cache_read) a odhad ceny.
struct SpendWindow: Equatable {
    var tokens: Int = 0
    var costUSD: Double = 0

    mutating func add(tokens t: Int, cost c: Double) {
        tokens += t
        costUSD += c
    }
}

/// Přehled spendu za čtyři okna. `computedAt == nil` = ještě nespočítáno.
struct SpendSummary: Equatable {
    var last24h = SpendWindow()
    var last7d = SpendWindow()
    var last31d = SpendWindow()
    var thisYear = SpendWindow()
    var computedAt: Date? = nil
}

/// Odhad ceny formátovaný do USD („$8.40", nad $100 bez centů).
func shortUSD(_ v: Double) -> String {
    v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
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

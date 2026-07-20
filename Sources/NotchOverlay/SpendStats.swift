import Foundation

/// Jeden zaznamenaný spend event z transkriptu.
struct SpendEvent {
    let date: Date
    let tokens: Int   // input + cache_creation + output + cache_read
    let cost: Double
}

/// Agreguje historickou spotřebu z transkriptů (`~/.claude/projects/*/*.jsonl`)
/// do oken 24h / 7d / 31d / tento rok. Počítá se na vyžádání (při otevření okna
/// nastavení), na pozadí. Full rescan — prořezáno podle mtime souboru, žádné
/// inkrementální offsety ani perzistence.
final class SpendStats {
    private let projectsDir: String
    private let queue = DispatchQueue(label: "spend-stats", qos: .userInitiated)

    init(projectsDir: String = NSString(string: "~/.claude/projects").expandingTildeInPath) {
        self.projectsDir = projectsDir
    }

    /// Spočítá summary na pozadí a zavolá completion na main threadu.
    func compute(completion: @escaping (SpendSummary) -> Void) {
        queue.async {
            let summary = self.scan()
            DispatchQueue.main.async { completion(summary) }
        }
    }

    /// Synchronní jádro — projde soubory a vrátí summary. `now`/`calendar`
    /// injektovatelné kvůli testovatelnosti.
    func scan(now: Date = Date(), calendar: Calendar = .current) -> SpendSummary {
        let yearStart = Self.startOfYear(now, calendar)
        var events: [SpendEvent] = []
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            var empty = SpendSummary(); empty.computedAt = now; return empty
        }
        for project in projects {
            let dir = (projectsDir as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(file)
                // Soubor nezapsaný od začátku roku nemůže mít letošní eventy → přeskoč.
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date, mtime < yearStart { continue }
                events.append(contentsOf: Self.parseFile(path))
            }
        }
        return Self.aggregate(events, now: now, calendar: calendar)
    }

    /// Rozparsuje jeden transkript na spend eventy (stejná pravidla jako UsageStats).
    static func parseFile(_ path: String) -> [SpendEvent] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [SpendEvent] = []
        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = parseISO(ts)
            else { continue }
            let model = (msg["model"] as? String) ?? ""
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let total = input + cacheCreation + output + cacheRead
            let cost = Pricing.cost(input: input, cacheCreation: cacheCreation,
                                    output: output, cacheRead: cacheRead, model: model)
            out.append(SpendEvent(date: date, tokens: total, cost: cost))
        }
        return out
    }

    /// Čisté jádro agregace — nasčítá eventy do oken podle jejich data.
    static func aggregate(_ events: [SpendEvent], now: Date, calendar: Calendar) -> SpendSummary {
        var s = SpendSummary()
        let c24 = now.addingTimeInterval(-24 * 3600)
        let c7 = now.addingTimeInterval(-7 * 24 * 3600)
        let c31 = now.addingTimeInterval(-31 * 24 * 3600)
        let yearStart = startOfYear(now, calendar)
        for e in events {
            if e.date >= c24 { s.last24h.add(tokens: e.tokens, cost: e.cost) }
            if e.date >= c7 { s.last7d.add(tokens: e.tokens, cost: e.cost) }
            if e.date >= c31 { s.last31d.add(tokens: e.tokens, cost: e.cost) }
            if e.date >= yearStart { s.thisYear.add(tokens: e.tokens, cost: e.cost) }
        }
        s.computedAt = now
        return s
    }

    private static func startOfYear(_ now: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
    }
}

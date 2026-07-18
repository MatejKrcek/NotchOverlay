import Foundation

/// Agreguje spotřebu tokenů z transkriptů (styl ccusage): 5h okno + dnešek.
/// Inkrementální — pamatuje si offset v každém souboru a dočítá jen přírůstky.
final class UsageStats {
    var onUpdate: ((UsageSummary) -> Void)?

    private let queue = DispatchQueue(label: "usage-stats", qos: .background)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var events: [(date: Date, output: Int, cost: Double)] = []

    private let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath

    // Hrubý odhad ceny za 1M tokenů (input, output, cache read)
    private func pricing(for model: String) -> (inp: Double, out: Double, cache: Double) {
        if model.contains("haiku") { return (0.8, 4, 0.08) }
        if model.contains("sonnet") { return (3, 15, 0.3) }
        return (15, 75, 1.5)  // opus / fable
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    private func refresh() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-26 * 3600)
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for project in projects {
            let dir = (projectsDir as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date, mtime > cutoff
                else { continue }
                ingest(path: path)
            }
        }

        let now = Date()
        events.removeAll { now.timeIntervalSince($0.date) > 26 * 3600 }

        var sum = UsageSummary()
        let fiveH = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        for e in events {
            if e.date >= fiveH {
                sum.fiveHourOutputTokens += e.output
                sum.fiveHourCostUSD += e.cost
            }
            if e.date >= midnight {
                sum.todayOutputTokens += e.output
                sum.todayCostUSD += e.cost
            }
        }
        DispatchQueue.main.async { self.onUpdate?(sum) }
    }

    private func ingest(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = offsets[path] ?? 0
        guard size > start else { offsets[path] = size; return }
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            offsets[path] = size
            return
        }
        // zpracovat jen kompletní řádky; nekompletní zbytek dočteme příště
        var consumed = start
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            consumed += UInt64(line.utf8.count) + 1
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
            let p = pricing(for: model)
            let inp = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            let out = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cost = Double(inp) / 1e6 * p.inp
                     + Double(out) / 1e6 * p.out
                     + Double(cacheRead) / 1e6 * p.cache
            events.append((date, out, cost))
        }
        offsets[path] = consumed
    }
}

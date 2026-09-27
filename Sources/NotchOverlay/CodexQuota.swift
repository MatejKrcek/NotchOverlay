import Foundation

/// Paid: limity Codexu čtené lokálně z rollout souborů ~/.codex/sessions —
/// token_count eventy nesou rate_limits.primary (used_percent, resets_at).
/// Plány bez oken (business/kredity) mají primary null — pak aspoň plan_type.
/// Žádné API; jen tail nejnovějšího souboru, cache 60 s.
enum CodexQuota {
    enum Info {
        case window(pct: Int, resetsAt: Date?)
        case planOnly(String)   // plán bez limit oken, např. "business"
        /// Přihlášení API klíčem — Codex nehlásí žádná okna (rate_limits je vždy null).
        case apiKey
    }

    private static var cached: Info??
    private static var cachedAt = Date.distantPast

    static func latest() -> Info? {
        if Date().timeIntervalSince(cachedAt) < 60, let c = cached { return c }
        let value = read()
        cached = value
        cachedAt = Date()
        return value
    }

    private static func read() -> Info? {
        // Nejdřív zkusit reálná okna ze session souborů; když žádná nejsou a
        // uživatel je přihlášený API klíčem, je to očekávané — říct to místo „no data".
        if let fromSessions = readSessions() { return fromSessions }
        return Providers.codexAuthMode() == "apikey" ? .apiKey : nil
    }

    private static func readSessions() -> Info? {
        let root = NSString(string: "~/.codex/sessions").expandingTildeInPath
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return nil }
        var newest: (path: String, mtime: Date)?
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (path, mtime) }
        }
        guard let newest, let fh = FileHandle(forReadingAtPath: newest.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        try? fh.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var planType: String?
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            if let primary = findPrimary(in: obj),
               let used = (primary["used_percent"] as? Double)
                       ?? (primary["used_percent"] as? Int).map(Double.init) {
                var resets: Date?
                if let t = (primary["resets_at"] as? Double) ?? (primary["resets_at"] as? Int).map(Double.init) {
                    resets = Date(timeIntervalSince1970: t)
                }
                return .window(pct: max(0, min(100, Int(used.rounded()))), resetsAt: resets)
            }
            if planType == nil, let p = findValue(forKey: "plan_type", in: obj) as? String {
                planType = p
            }
        }
        return planType.map { .planOnly($0) }
    }

    private static func findValue(forKey key: String, in obj: [String: Any]) -> Any? {
        if let v = obj[key] { return v }
        for v in obj.values {
            if let sub = v as? [String: Any], let found = findValue(forKey: key, in: sub) { return found }
        }
        return nil
    }

    /// rate_limits.primary může být různě zanořené podle verze Codexu.
    private static func findPrimary(in obj: [String: Any]) -> [String: Any]? {
        if let p = obj["primary"] as? [String: Any], p["used_percent"] != nil { return p }
        for v in obj.values {
            if let sub = v as? [String: Any], let found = findPrimary(in: sub) { return found }
        }
        return nil
    }
}

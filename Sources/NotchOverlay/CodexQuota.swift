import Foundation

/// Paid: limity Codexu čtené lokálně z rollout souborů ~/.codex/sessions —
/// token_count eventy nesou rate_limits.primary (used_percent, resets_at).
/// Žádné API; jen tail nejnovějšího souboru, cache 60 s.
enum CodexQuota {
    private static var cached: (pct: Int, resetsAt: Date?)??
    private static var cachedAt = Date.distantPast

    static func latest() -> (pct: Int, resetsAt: Date?)? {
        if Date().timeIntervalSince(cachedAt) < 60, let c = cached { return c }
        let value = read()
        cached = value
        cachedAt = Date()
        return value
    }

    private static func read() -> (pct: Int, resetsAt: Date?)? {
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

        for line in text.split(separator: "\n").reversed() where line.contains("used_percent") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let primary = findPrimary(in: obj),
                  let used = (primary["used_percent"] as? Double)
                          ?? (primary["used_percent"] as? Int).map(Double.init)
            else { continue }
            var resets: Date?
            if let t = (primary["resets_at"] as? Double) ?? (primary["resets_at"] as? Int).map(Double.init) {
                resets = Date(timeIntervalSince1970: t)
            }
            return (max(0, min(100, Int(used.rounded()))), resets)
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

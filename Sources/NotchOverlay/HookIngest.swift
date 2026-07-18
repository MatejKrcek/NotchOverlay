import Foundation

/// Konzumuje eventy z Claude Code hooků. Hook skript (hooks/vibe-event.sh)
/// uloží JSON ze stdin do ~/.claude/vibe-events/*.evt; tady je čteme a mažeme.
/// Žádný server, žádné porty — jen adresář jako fronta.
final class HookIngest {
    var onEvent: ((_ sessionId: String, _ state: SessionState?, _ termProgram: String?, _ ended: Bool) -> Void)?

    private let queue = DispatchQueue(label: "hook-ingest", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let dir = NSString(string: "~/.claude/vibe-events").expandingTildeInPath

    func start() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for f in files.sorted() where f.hasSuffix(".evt") {
            let path = (dir as NSString).appendingPathComponent(f)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                process(text)
            }
            try? fm.removeItem(atPath: path)
        }
    }

    private func process(_ text: String) {
        // Soubor obsahuje 1+ řádků JSONu (event ze stdin + přibalené env info) — mergujeme.
        var merged: [String: Any] = [:]
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                merged.merge(obj) { a, _ in a }
            }
        }
        guard let sessionId = merged["session_id"] as? String,
              let event = merged["hook_event_name"] as? String
        else { return }

        let term = (merged["env_term"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var state: SessionState?
        var ended = false

        switch event {
        case "Notification":
            let msg = (merged["message"] as? String) ?? ""
            let lower = msg.lowercased()
            if lower.contains("permission") || lower.contains("approval") {
                // "Claude needs your permission to use Bash" -> vytáhnout název nástroje
                let tool = msg.split(separator: " ").last.map(String.init) ?? "tool"
                state = .permission(tool)
            } else if lower.contains("waiting") || lower.contains("input") {
                state = .question
            } else {
                state = .question
            }
        case "Stop", "SubagentStop":
            state = .done
        case "SessionEnd":
            ended = true
        case "SessionStart":
            state = nil  // jen si zapamatujeme termProgram
        default:
            return
        }
        DispatchQueue.main.async { self.onEvent?(sessionId, state, term, ended) }
    }
}

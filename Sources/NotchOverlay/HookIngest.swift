import Foundation

/// Konzumuje eventy z Claude Code hooků. Hook skript (hooks/vibe-event.sh)
/// uloží JSON ze stdin do ~/.claude/vibe-events/*.evt; tady je čteme a mažeme.
/// Žádný server, žádné porty — jen adresář jako fronta.
///
/// Adresář hlídá vnode DispatchSource (žádný polling): reagujeme jen na zápis.
final class HookIngest {
    var onEvent: ((_ sessionId: String, _ state: SessionState?, _ termProgram: String?, _ ended: Bool) -> Void)?

    private let queue = DispatchQueue(label: "hook-ingest", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private let dir = NSString(string: "~/.claude/vibe-events").expandingTildeInPath

    func start() {
        queue.async {
            self.arm()
            self.drain()
        }
    }

    /// Otevře adresář a pověsí na něj vnode source. Při smazání/přejmenování
    /// adresáře ho znovu vytvoří a pověsí znovu.
    private func arm() {
        source?.cancel()
        source = nil
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry(after: 2)  // adresář nejde otevřít — zkusit později
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue
        )
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if s.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.drain()
            } else {
                self.arm()
                self.drain()
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retry?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.retry = nil
            if self.source == nil { self.arm() }
            self.drain()
        }
        t.resume()
        retry = t
    }

    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        var sawIncomplete = false
        for f in files.sorted() where f.hasSuffix(".evt") {
            let path = (dir as NSString).appendingPathComponent(f)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            // Vnode event přijde už při vytvoření souboru; skript ještě může psát.
            // Kompletní soubor končí newline (printf ve skriptu) — jinak zkusit za chvíli.
            guard text.hasSuffix("\n") else { sawIncomplete = true; continue }
            process(text)
            try? fm.removeItem(atPath: path)
        }
        if sawIncomplete { scheduleRetry(after: 0.15) }
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

import Foundation

/// Pasivně sleduje ~/.claude/projects/**/*.jsonl a odvozuje stav běžících
/// Claude Code sessions z posledních záznamů transkriptu + mtime souboru.
/// Hook eventy (HookIngest) stavy zpřesňují — mají přednost po dobu platnosti.
final class SessionMonitor {
    var onUpdate: (([AgentSession]) -> Void)?
    var onStateChange: ((AgentSession, SessionState?) -> Void)?  // (session, předchozí stav) — pro zvuky

    private let queue = DispatchQueue(label: "session-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var titleCache: [String: String] = [:]      // sessionId -> aiTitle
    private var lastStates: [String: SessionState] = [:]
    private var hookOverrides: [String: (state: SessionState, at: Date, termProgram: String?)] = [:]
    private var endedSessions: Set<String> = []

    private let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
    /// Session se zobrazuje, dokud od poslední aktivity neuplyne tenhle čas.
    private let visibilityWindow: TimeInterval = 30 * 60
    /// Po jak dlouhé nečinnosti u otevřeného tool_use usoudíme, že se čeká na permission.
    /// Skutečné permission requesty hlásí hooky okamžitě; tohle je jen záchytná síť,
    /// takže velkoryse — dlouhý build v Bashi není „zaseknuto".
    private let stallThreshold: TimeInterval = 45

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    // MARK: - Hook eventy

    func applyHookEvent(sessionId: String, state: SessionState?, termProgram: String?, ended: Bool) {
        queue.async {
            if ended {
                self.endedSessions.insert(sessionId)
                self.hookOverrides[sessionId] = nil
                return
            }
            self.endedSessions.remove(sessionId)
            if let state {
                self.hookOverrides[sessionId] = (state, Date(), termProgram)
            } else if let termProgram {
                let prev = self.hookOverrides[sessionId]
                if let prev { self.hookOverrides[sessionId] = (prev.state, prev.at, termProgram) }
                else { self.hookOverrides[sessionId] = (.idle, .distantPast, termProgram) }
            }
        }
    }

    // MARK: - Scan

    private func scan() {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }
        var sessions: [AgentSession] = []
        let now = Date()

        for project in projects {
            let dir = (projectsDir as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < visibilityWindow
                else { continue }
                if var s = parseSession(path: path, mtime: mtime) {
                    if endedSessions.contains(s.id) { continue }
                    // Hook override: permission/question drží, dokud transkript nepokročí za čas eventu
                    if let ov = hookOverrides[s.id] {
                        s.termProgram = ov.termProgram ?? s.termProgram
                        if ov.at > mtime.addingTimeInterval(-1), ov.state != .idle {
                            s.state = ov.state
                        } else if case .working = s.state {
                            hookOverrides[s.id] = (ov.state, .distantPast, ov.termProgram)
                        }
                    }
                    sessions.append(s)
                }
            }
        }

        sessions.sort { ($0.state.priority, $1.lastActivity.timeIntervalSince1970)
                      < ($1.state.priority, $0.lastActivity.timeIntervalSince1970) }

        // Zvuky: detekce přechodů
        for s in sessions {
            let prev = lastStates[s.id]
            if prev != s.state { onStateChange?(s, prev) }
            lastStates[s.id] = s.state
        }

        DispatchQueue.main.async { self.onUpdate?(sessions) }
    }

    // MARK: - Parsování transkriptu

    private func parseSession(path: String, mtime: Date) -> AgentSession? {
        guard let tail = tailLines(path: path, bytes: 262_144) else { return nil }

        var sessionId: String?
        var title: String?
        var cwd: String?
        var branch: String?
        var model = ""
        var lastKind: String?        // "assistant-tool" / "assistant-text" / "user" / "user-prompt"
        var lastToolName = ""
        var lastTimestamp: Date?

        for line in tail {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let t = obj["aiTitle"] as? String { title = t }
            guard (obj["isSidechain"] as? Bool) != true else { continue }
            guard let type = obj["type"] as? String else { continue }

            if let sid = obj["sessionId"] as? String { sessionId = sid }
            if let c = obj["cwd"] as? String { cwd = c }
            if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            if let ts = obj["timestamp"] as? String, let d = parseISO(ts) { lastTimestamp = d }

            switch type {
            case "assistant":
                if (obj["isApiErrorMessage"] as? Bool) == true {
                    lastKind = "error"
                    continue
                }
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let m = msg["model"] as? String { model = shortModelName(m) }
                var sawTool = false
                if let content = msg["content"] as? [[String: Any]] {
                    for c in content where (c["type"] as? String) == "tool_use" {
                        sawTool = true
                        lastToolName = (c["name"] as? String) ?? "tool"
                    }
                }
                lastKind = sawTool ? "assistant-tool" : "assistant-text"
            case "user":
                if (obj["isMeta"] as? Bool) == true { continue }
                var isPrompt = false
                if let msg = obj["message"] as? [String: Any] {
                    if let s = msg["content"] as? String { isPrompt = !s.isEmpty }
                    else if let arr = msg["content"] as? [[String: Any]] {
                        isPrompt = !arr.contains { ($0["type"] as? String) == "tool_result" }
                    }
                }
                lastKind = isPrompt ? "user-prompt" : "user"
            default:
                break
            }
        }

        guard let sid = sessionId else { return nil }
        if let t = title { titleCache[sid] = t }
        let resolvedTitle = titleCache[sid] ?? title ?? projectName(from: cwd) ?? "session"
        let idleFor = Date().timeIntervalSince(mtime)

        let state: SessionState
        switch lastKind {
        case "assistant-tool":
            state = idleFor < stallThreshold
                ? .working(lastToolName)
                : .stalled(lastToolName)
        case "user", "user-prompt":
            state = idleFor < stallThreshold ? .working("thinking…") : .stalled("no response")
        case "assistant-text":
            state = idleFor < 3 ? .working("writing…") : .done
        case "error":
            state = .failed("API error")
        default:
            state = .idle
        }

        return AgentSession(
            id: sid,
            title: resolvedTitle,
            project: projectName(from: cwd) ?? "?",
            branch: branch,
            model: model,
            state: state,
            lastActivity: lastTimestamp ?? mtime,
            termProgram: nil,
            transcriptPath: path
        )
    }

    private func projectName(from cwd: String?) -> String? {
        guard let cwd else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    /// Přečte posledních `bytes` bajtů souboru a vrátí kompletní řádky.
    private func tailLines(path: String, bytes: Int) -> [String]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(),
              var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return nil }
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])  // zahodit useknutý první řádek
        }
        return text.split(separator: "\n").map(String.init)
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoFormatterNoFrac = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
}

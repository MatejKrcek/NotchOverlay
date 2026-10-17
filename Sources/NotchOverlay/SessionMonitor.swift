import Foundation
import CoreServices

/// Pasivně sleduje ~/.claude/projects/**/*.jsonl a odvozuje stav běžících
/// Claude Code sessions z posledních záznamů transkriptu + mtime souboru.
/// Hook eventy (HookIngest) stavy zpřesňují — mají přednost po dobu platnosti.
///
/// Šetření baterie: žádný rychlý polling. Sken spouští
///   1. FSEvents na adresáři projektů (změna transkriptu),
///   2. jednorázový timer na nejbližší časový práh (např. „writing…" → done po 3 s),
///   3. hook event,
///   4. pomalá pojistka (20 s, s tolerancí) kdyby FSEvents selhaly.
/// Transkripty se parsují inkrementálně — čte se jen přírůstek od minula.
final class SessionMonitor {
    var onUpdate: (([AgentSession]) -> Void)?
    var onStateChange: ((AgentSession, SessionState?) -> Void)?  // (session, předchozí stav) — pro zvuky

    private let queue = DispatchQueue(label: "session-monitor", qos: .utility)
    private var safetyTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var fsStream: FSEventStreamRef?
    private var titleCache: [String: String] = [:]      // sessionId -> aiTitle
    private var lastStates: [String: SessionState] = [:]
    private var hookOverrides: [String: (state: SessionState, at: Date, termProgram: String?)] = [:]
    private var endedSessions: Set<String> = []
    private var transcripts: [String: TranscriptState] = [:]  // path -> inkrementální stav parseru
    private var lastEmitted: [AgentSession]?

    private let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
    /// Session se zobrazuje, dokud od poslední aktivity neuplyne tenhle čas.
    private let visibilityWindow: TimeInterval = 30 * 60
    /// Po jak dlouhé nečinnosti u otevřeného tool_use usoudíme, že se čeká na permission.
    /// Skutečné permission requesty hlásí hooky okamžitě; tohle je jen záchytná síť,
    /// takže velkoryse — dlouhý build v Bashi není „zaseknuto".
    private let stallThreshold: TimeInterval = 45
    /// „writing…" se po tolika sekundách bez zápisu překlopí na done.
    private let writingThreshold: TimeInterval = 3
    /// Při prvním načtení souboru se čte jen tenhle ocas.
    private let initialTailBytes: UInt64 = 262_144

    func start() {
        try? FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)
        startFSEvents()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 20, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        safetyTimer = t
    }

    deinit {
        if let fsStream {
            FSEventStreamStop(fsStream)
            FSEventStreamInvalidate(fsStream)
            FSEventStreamRelease(fsStream)
        }
    }

    // MARK: - Spouštěče skenu

    private func startFSEvents() {
        var ctx = FSEventStreamContext()
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue().scan()
        }
        // latence 0.5 s: dávky zápisů během streamování se slučují do jednoho skenu
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx, [projectsDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        fsStream = stream
    }

    /// Naplánuje jednorázový sken na okamžik, kdy se překlopí nejbližší časový práh.
    private func scheduleDeadline(in seconds: TimeInterval?) {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let seconds else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(0.05, seconds + 0.1), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        deadlineTimer = t
    }

    // MARK: - Hook eventy

    func applyHookEvent(sessionId: String, state: SessionState?, termProgram: String?, ended: Bool) {
        queue.async {
            if ended {
                self.endedSessions.insert(sessionId)
                self.hookOverrides[sessionId] = nil
            } else {
                self.endedSessions.remove(sessionId)
                if let state {
                    self.hookOverrides[sessionId] = (state, Date(), termProgram)
                } else if let termProgram {
                    let prev = self.hookOverrides[sessionId]
                    if let prev { self.hookOverrides[sessionId] = (prev.state, prev.at, termProgram) }
                    else { self.hookOverrides[sessionId] = (.idle, .distantPast, termProgram) }
                }
            }
            self.scan()
        }
    }

    // MARK: - Scan

    private func scan() {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }
        var sessions: [AgentSession] = []
        var seen: Set<String> = []
        var nextFlip: TimeInterval?
        let now = Date()

        for project in projects {
            let dir = (projectsDir as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }
                let idleFor = now.timeIntervalSince(mtime)
                guard idleFor < visibilityWindow else { continue }
                seen.insert(path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                updateTranscript(path: path, size: size, mtime: mtime)
                guard var s = session(for: path, mtime: mtime, idleFor: idleFor) else { continue }

                // Časové prahy: kdy se stav souboru změní sám od sebe bez zápisu
                var thresholds = [visibilityWindow]
                switch transcripts[path]?.lastKind {
                case "assistant-text": thresholds.append(writingThreshold)
                case "assistant-tool", "user", "user-prompt": thresholds.append(stallThreshold)
                default: break
                }
                for th in thresholds where th > idleFor {
                    nextFlip = min(nextFlip ?? .infinity, th - idleFor)
                }

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

        // Zapomenout parser stav souborů, které vypadly z okna viditelnosti
        for path in transcripts.keys where !seen.contains(path) { transcripts[path] = nil }

        sessions.sort { ($0.state.priority, $1.lastActivity.timeIntervalSince1970)
                      < ($1.state.priority, $0.lastActivity.timeIntervalSince1970) }

        // Zvuky: detekce přechodů
        for s in sessions {
            let prev = lastStates[s.id]
            if prev != s.state { onStateChange?(s, prev) }
            lastStates[s.id] = s.state
        }

        scheduleDeadline(in: nextFlip)

        guard sessions != lastEmitted else { return }
        lastEmitted = sessions
        DispatchQueue.main.async { self.onUpdate?(sessions) }
    }

    // MARK: - Inkrementální parsování transkriptu

    private struct TranscriptState {
        var offset: UInt64 = 0      // kam až jsme přečetli (jen kompletní řádky)
        var size: UInt64 = 0
        var mtime: Date = .distantPast
        var sessionId: String?
        var title: String?
        var cwd: String?
        var branch: String?
        var model = ""
        var lastKind: String?        // "assistant-tool" / "assistant-text" / "user" / "user-prompt" / "error"
        var lastToolName = ""
        var lastTimestamp: Date?
    }

    /// Dočte přírůstek souboru od minula. Když se soubor nezměnil, nic nečte.
    private func updateTranscript(path: String, size: UInt64, mtime: Date) {
        var st = transcripts[path] ?? TranscriptState()
        let isNew = transcripts[path] == nil
        if size < st.offset {  // zkrácen / přepsán → od začátku
            st = TranscriptState()
        }
        if !isNew, size == st.size, mtime == st.mtime { return }
        st.size = size
        st.mtime = mtime

        var start = st.offset
        var skipPartialFirst = false
        if isNew, size > initialTailBytes {
            start = size - initialTailBytes
            skipPartialFirst = true
        }
        if size > start, let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: start)
            if let data = try? fh.readToEnd() {
                var consumed = start
                var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                let partialTail = lines.last.map { !$0.isEmpty } ?? false
                if partialTail { lines.removeLast() } else if !lines.isEmpty { lines.removeLast() }  // prázdný konec za posledním \n
                for (i, line) in lines.enumerated() {
                    consumed += UInt64(line.count) + 1
                    if i == 0, skipPartialFirst { continue }  // useknutý první řádek ocasu
                    guard !line.isEmpty else { continue }
                    apply(line: line, to: &st)
                }
                st.offset = consumed
            }
        }
        transcripts[path] = st
    }

    private func apply(line: Data, to st: inout TranscriptState) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let t = obj["aiTitle"] as? String { st.title = t }
        guard (obj["isSidechain"] as? Bool) != true else { return }
        guard let type = obj["type"] as? String else { return }

        if let sid = obj["sessionId"] as? String { st.sessionId = sid }
        if let c = obj["cwd"] as? String { st.cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { st.branch = b }
        if let ts = obj["timestamp"] as? String, let d = parseISO(ts) { st.lastTimestamp = d }

        switch type {
        case "assistant":
            if (obj["isApiErrorMessage"] as? Bool) == true {
                st.lastKind = "error"
                return
            }
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let m = msg["model"] as? String { st.model = shortModelName(m) }
            var sawTool = false
            if let content = msg["content"] as? [[String: Any]] {
                for c in content where (c["type"] as? String) == "tool_use" {
                    sawTool = true
                    st.lastToolName = (c["name"] as? String) ?? "tool"
                }
            }
            st.lastKind = sawTool ? "assistant-tool" : "assistant-text"
        case "user":
            if (obj["isMeta"] as? Bool) == true { return }
            var isPrompt = false
            if let msg = obj["message"] as? [String: Any] {
                if let s = msg["content"] as? String { isPrompt = !s.isEmpty }
                else if let arr = msg["content"] as? [[String: Any]] {
                    isPrompt = !arr.contains { ($0["type"] as? String) == "tool_result" }
                }
            }
            st.lastKind = isPrompt ? "user-prompt" : "user"
        default:
            break
        }
    }

    /// Z naparsovaného stavu + aktuálního času odvodí AgentSession.
    private func session(for path: String, mtime: Date, idleFor: TimeInterval) -> AgentSession? {
        guard let st = transcripts[path], let sid = st.sessionId else { return nil }
        if let t = st.title { titleCache[sid] = t }
        let resolvedTitle = titleCache[sid] ?? st.title ?? projectName(from: st.cwd) ?? "session"

        let state: SessionState
        switch st.lastKind {
        case "assistant-tool":
            state = idleFor < stallThreshold
                ? .working(st.lastToolName)
                : .stalled(st.lastToolName)
        case "user", "user-prompt":
            state = idleFor < stallThreshold ? .working("thinking…") : .stalled("no response")
        case "assistant-text":
            state = idleFor < writingThreshold ? .working("writing…") : .done
        case "error":
            state = .failed("API error")
        default:
            state = .idle
        }

        return AgentSession(
            id: sid,
            title: resolvedTitle,
            project: projectName(from: st.cwd) ?? "?",
            branch: st.branch,
            model: st.model,
            state: state,
            lastActivity: st.lastTimestamp ?? mtime,
            termProgram: nil,
            transcriptPath: path
        )
    }

    private func projectName(from cwd: String?) -> String? {
        guard let cwd else { return nil }
        return (cwd as NSString).lastPathComponent
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

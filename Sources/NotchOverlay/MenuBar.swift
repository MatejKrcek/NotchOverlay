import AppKit

/// Položka v pravé části menu baru: jen 5h session Claude — využití
/// (např. „5h 16%"), volitelně čas resetu (např. „17:30"). Mód se přepíná
/// v nastavení (Off / Usage % / Reset time), viz Display.menuBarFiveHour.
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private var timer: Timer?
    private var fiveHour: QuotaWindow?
    private var signedOut = false
    /// Token Claude Code prošel — hodnota je poslední známá, ne aktuální.
    private var stale = false
    private var infoItem: NSMenuItem?

    func start() { applyMode() }

    /// Po změně nastavení: vytvoří/zruší položku podle zvoleného módu.
    func applyMode() {
        guard Display.menuBarFiveHour != "off" else {
            timer?.invalidate()
            timer = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.menu = buildMenu()
            item = it
        }
        if timer == nil {
            // countdown tiká po půl minutě — přesnost na minuty stačí
            let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.render()
            }
            t.tolerance = 5
            timer = t
        }
        render()
    }

    func update(quotaState: QuotaFetchState) {
        switch quotaState {
        case .ok(let q):
            fiveHour = q.fiveHour
            signedOut = false
            stale = false
        case .signedOut:
            signedOut = true
            stale = false
        case .stale:
            stale = true
        default:
            break  // přechodná chyba — držet poslední hodnotu
        }
        render()
    }

    private func render() {
        guard let button = item?.button else { return }
        button.attributedTitle = attributedTitle()
        infoItem?.title = detail()
        button.toolTip = detail()
    }

    /// „5h" malým sekundárním písmem, hodnota (procenta / čas resetu) normálně.
    private func attributedTitle() -> NSAttributedString {
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        guard let value = value() else {
            return NSAttributedString(string: "–", attributes: valueAttrs)
        }
        let s = NSMutableAttributedString(string: "5h\u{2009}", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .baselineOffset: 0.5,
        ])
        s.append(NSAttributedString(string: value, attributes: valueAttrs))
        return s
    }

    private func value() -> String? {
        guard !signedOut, let w = fiveHour else { return nil }
        if Display.menuBarFiveHour == "reset" {
            guard let reset = w.resetsAt, reset.timeIntervalSinceNow > 0 else { return nil }
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            return f.string(from: reset)
        }
        return stale ? "~\(w.pct)%" : "\(w.pct)%"
    }

    private func detail() -> String {
        if signedOut { return "Claude: not signed in" }
        let staleNote = stale ? " · stale (Claude Code token expired, waiting for refresh)" : ""
        guard let w = fiveHour, let reset = w.resetsAt, reset.timeIntervalSinceNow > 0 else {
            return "5h session: no active window" + staleNote
        }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return "5h session: \(w.pct) % used · resets \(f.string(from: reset))" + staleNote
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let info = NSMenuItem(title: detail(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        infoItem = info
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ""))
        menu.items.last?.target = self
        return menu
    }

    @objc private func openSettings() {
        MainWindowController.shared.present()
    }
}

import AppKit

/// Hlavní okno appky — otevře se kliknutím na appku ve Finderu/Docku
/// (reopen) nebo při ručním spuštění. Overlay on/off, zvuky, login, quit.
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    var isOverlayOn: (() -> Bool)?
    var setOverlayOn: ((Bool) -> Void)?
    var onSignIn: (() -> Void)?
    var onSizeChange: (() -> Void)?

    private var window: NSWindow?
    private var overlaySwitch: NSSwitch?
    private var soundsSwitch: NSSwitch?
    private var sizeSlider: NSSlider?

    func present() {
        if window == nil { buildWindow() }
        overlaySwitch?.state = (isOverlayOn?() ?? true) ? .on : .off
        soundsSwitch?.state = Sounds.shared.enabled ? .on : .off
        let scale = UserDefaults.standard.double(forKey: "islandScale")
        sizeSlider?.doubleValue = scale == 0 ? 1 : scale
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let width = 400.0
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 368),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "NotchOverlay"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 368))

        let icon = NSImageView(frame: NSRect(x: width / 2 - 32, y: 288, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        v.addSubview(icon)

        let title = NSTextField(labelWithString: "NotchOverlay")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 258, width: width, height: 24)
        v.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Dynamic Island for Claude Code agents")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: 238, width: width, height: 16)
        v.addSubview(subtitle)

        let overlayLabel = NSTextField(labelWithString: "Island in the notch")
        overlayLabel.frame = NSRect(x: 24, y: 196, width: 250, height: 20)
        v.addSubview(overlayLabel)
        let overlay = NSSwitch(frame: NSRect(x: width - 24 - 38, y: 192, width: 38, height: 24))
        overlay.target = self
        overlay.action = #selector(toggleOverlay(_:))
        v.addSubview(overlay)
        overlaySwitch = overlay

        let soundsLabel = NSTextField(labelWithString: "Sounds")
        soundsLabel.frame = NSRect(x: 24, y: 160, width: 250, height: 20)
        v.addSubview(soundsLabel)
        let sounds = NSSwitch(frame: NSRect(x: width - 24 - 38, y: 156, width: 38, height: 24))
        sounds.target = self
        sounds.action = #selector(toggleSounds(_:))
        v.addSubview(sounds)
        soundsSwitch = sounds

        let sizeLabel = NSTextField(labelWithString: "Island size")
        sizeLabel.frame = NSRect(x: 24, y: 124, width: 120, height: 20)
        v.addSubview(sizeLabel)
        let slider = NSSlider(value: 1, minValue: 1, maxValue: 1.5,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 150, y: 120, width: width - 150 - 24 - 66, height: 24)
        v.addSubview(slider)
        sizeSlider = slider
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSize(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)
        reset.frame = NSRect(x: width - 24 - 58, y: 120, width: 58, height: 22)
        v.addSubview(reset)

        let signIn = NSButton(title: "Sign in with Claude…", target: self, action: #selector(signIn(_:)))
        signIn.bezelStyle = .rounded
        signIn.frame = NSRect(x: 24, y: 72, width: width - 48, height: 32)
        v.addSubview(signIn)

        let quit = NSButton(title: "Quit NotchOverlay", target: self, action: #selector(quit(_:)))
        quit.bezelStyle = .rounded
        quit.hasDestructiveAction = true
        quit.frame = NSRect(x: 24, y: 38, width: width - 48, height: 32)
        v.addSubview(quit)

        let note = NSTextField(wrappingLabelWithString:
            "Quit stops the app until your next login (or manual launch).")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 24, y: 14, width: width - 48, height: 16)
        v.addSubview(note)

        w.contentView = v
        window = w
    }

    @objc private func toggleOverlay(_ sender: NSSwitch) {
        setOverlayOn?(sender.state == .on)
    }

    @objc private func toggleSounds(_ sender: NSSwitch) {
        Sounds.shared.enabled = sender.state == .on
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "islandScale")
        onSizeChange?()
    }

    @objc private func resetSize(_ sender: NSButton) {
        UserDefaults.standard.removeObject(forKey: "islandScale")
        sizeSlider?.doubleValue = 1
        onSizeChange?()
    }

    @objc private func signIn(_ sender: NSButton) {
        onSignIn?()
    }

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

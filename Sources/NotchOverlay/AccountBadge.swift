import AppKit

/// Odznak Claude účtu: terakotové kolečko s bílou čtyřcípou jiskrou.
/// Kreslí se v kódu (žádný asset), aktivní účet plnou barvou, ostatní ztlumeně.
enum AccountBadge {
    static let tint = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)  // #D97757

    private static var cache: [String: NSImage] = [:]

    static func image(size: CGFloat, active: Bool) -> NSImage {
        let key = "\(size)-\(active)"
        if let img = cache[key] { return img }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            (active ? tint : tint.withAlphaComponent(0.35)).setFill()
            circle.fill()
            sparkle(in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
                .fill(with: NSColor.white.withAlphaComponent(active ? 1 : 0.75))
            return true
        }
        cache[key] = img
        return img
    }

    /// Štítek „IN USE" u účtu, ze kterého Claude Code právě čerpá.
    static func inUsePill(scale: CGFloat = 1) -> NSView {
        let label = NSTextField(labelWithString: "IN USE")
        label.font = .systemFont(ofSize: 8.5 * scale, weight: .bold)
        // světlý text na tmavém podkladu (island, tmavé nastavení), tmavší terakota ve světlém
        label.textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.98, green: 0.72, blue: 0.62, alpha: 1)
                : NSColor(srgbRed: 0.66, green: 0.29, blue: 0.18, alpha: 1)
        }
        label.alignment = .center
        let textW = ceil(label.attributedStringValue.size().width)
        let h = 13 * scale
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: textW + 10 * scale, height: h))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = h / 2
        pill.layer?.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        label.frame = NSRect(x: 0, y: (h - 11 * scale) / 2 - 0.5, width: pill.frame.width, height: 11 * scale)
        pill.addSubview(label)
        return pill
    }

    /// Čtyřcípá jiskra s prohnutými stranami (✦).
    private static func sparkle(in r: NSRect) -> NSBezierPath {
        let c = NSPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2, ry = r.height / 2
        let k: CGFloat = 0.16   // jak moc jsou strany prohnuté ke středu
        let p = NSBezierPath()
        let tips = [NSPoint(x: c.x, y: c.y + ry), NSPoint(x: c.x + rx, y: c.y),
                    NSPoint(x: c.x, y: c.y - ry), NSPoint(x: c.x - rx, y: c.y)]
        p.move(to: tips[0])
        for i in 0..<4 {
            let a = tips[i], b = tips[(i + 1) % 4]
            // řídicí bod blízko středu mezi dvěma cípy
            let ctrl = NSPoint(x: c.x + ((a.x - c.x) + (b.x - c.x)) * k,
                               y: c.y + ((a.y - c.y) + (b.y - c.y)) * k)
            p.curve(to: b, controlPoint1: ctrl, controlPoint2: ctrl)
        }
        p.close()
        return p
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

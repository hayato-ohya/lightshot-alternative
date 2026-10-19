import AppKit

/// Dark floating toolbar used for the tool palette and the action bar.
final class PaletteView: NSView {
    let stack = NSStackView()

    init(orientation: NSUserInterfaceLayoutOrientation) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()

        stack.orientation = orientation
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addButton(symbol: String, tooltip: String, target: AnyObject?, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        let button = NSButton(image: image, target: target, action: action)
        configure(button, tooltip: tooltip)
        stack.addArrangedSubview(button)
        return button
    }

    func addView(_ view: NSView) {
        stack.addArrangedSubview(view)
    }

    func configure(_ button: NSButton, tooltip: String) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.focusRingType = .none
        (button.cell as? NSButtonCell)?.highlightsBy = [.contentsCellMask]
    }

    static func setActive(_ button: NSButton, _ active: Bool) {
        button.layer?.backgroundColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : nil
    }

    func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
    }

    // Never let a click on the palette fall through to the overlay.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// Renders a filled circle swatch used for the color button.
func swatchImage(color: NSColor, size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        color.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        return true
    }
    return image
}

import AppKit
import UniformTypeIdentifiers

/// Shows a captured full page with Copy / Save actions (⌘C / ⌘S).
final class FullPagePreviewWindow: NSWindow {
    private let image: CGImage
    private let pageTitle: String

    init(image: CGImage, title: String, scale: CGFloat) {
        self.image = image
        self.pageTitle = title
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(pointSize.width + 2, visible.width * 0.9)
        let height = min(pointSize.height + 52, visible.height * 0.9)
        super.init(contentRect: NSRect(x: 0, y: 0, width: max(480, width), height: max(320, height)),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        self.title = title.isEmpty ? "Full Page Screenshot" : "Full Page – \(title)"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 360, height: 240)

        let content = NSView(frame: contentRect(forFrameRect: frame))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: pointSize))
        imageView.image = NSImage(cgImage: image, size: pointSize)
        imageView.imageScaling = .scaleNone
        imageView.imageFrameStyle = .none
        let flipped = FlippedClipView()
        flipped.addSubview(imageView)
        flipped.frame = NSRect(origin: .zero, size: pointSize)
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let sizeLabel = NSTextField(labelWithString: "\(image.width) × \(image.height) px")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(saveImage))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\u{1b}"
        for b in [copyButton, saveButton, closeButton] { b.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [sizeLabel, spacer, copyButton, saveButton, closeButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        contentView = content
        center()
    }

    @objc private func copyImage() {
        CaptureSession.copyToPasteboard(image)
        close()
    }

    @objc private func saveImage() {
        let prefs = Preferences.shared
        let panel = NSSavePanel()
        panel.directoryURL = prefs.saveDirectory
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Full Page \(f.string(from: Date())).\(prefs.imageFormat.fileExtension)"
        panel.beginSheetModal(for: self) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let format: ImageFormat = url.pathExtension.lowercased().hasPrefix("jp") ? .jpeg : .png
            do {
                try CaptureSession.write(image, to: url, format: format)
                prefs.saveDirectory = url.deletingLastPathComponent()
                if prefs.copyAfterSave { CaptureSession.copyToPasteboard(image) }
                close()
            } catch {
                NSAlert(error: error).beginSheetModal(for: self)
            }
        }
    }

    @objc private func closeWindow() {
        close()
    }

    private final class FlippedClipView: NSView {
        override var isFlipped: Bool { true }
    }
}

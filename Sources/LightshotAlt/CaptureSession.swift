import AppKit
import UniformTypeIdentifiers

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns one overlay window per display for the duration of a capture.
@MainActor
final class CaptureSession: OverlayViewDelegate {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var screens: [NSScreen] = []
    let mode: OverlayView.Mode
    var onFinish: (() -> Void)?
    /// Recording mode only: the user confirmed a region (points, relative to the screen's top-left).
    var onStartRecording: ((NSScreen, CGRect) -> Void)?
    /// Window-pick mode only: the user clicked a window.
    var onPickWindow: ((WindowInfo) -> Void)?
    private var finished = false

    init(result: CaptureResult, mode: OverlayView.Mode = .screenshot) {
        self.mode = mode
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for shot in result.shots {
            let screenFrame = shot.screen.frame
            // Convert global top-left-origin window frames into this screen's flipped local coords.
            let localWindows = result.windows.map { w in
                w.with(frame: CGRect(x: w.frame.minX - screenFrame.minX,
                                     y: w.frame.minY - (primaryHeight - screenFrame.maxY),
                                     width: w.frame.width, height: w.frame.height))
            }.filter { $0.frame.intersects(CGRect(origin: .zero, size: screenFrame.size)) }

            // Note: the `screen:` initializer treats contentRect as screen-relative, which misplaces
            // windows on displays whose origin is not (0,0). Use global coordinates instead.
            let window = OverlayWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screenFrame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true

            let container = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
            container.wantsLayer = true
            let imageView = NSImageView(frame: container.bounds)
            imageView.image = NSImage(cgImage: shot.image, size: screenFrame.size)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            container.addSubview(imageView)

            let overlay = OverlayView(frame: container.bounds, screenshot: shot.image,
                                      scale: shot.screen.backingScaleFactor, windows: localWindows, mode: mode)
            overlay.autoresizingMask = [.width, .height]
            overlay.delegate = self
            container.addSubview(overlay)

            window.contentView = container
            windows.append(window)
            views.append(overlay)
            screens.append(shot.screen)
        }
    }

    func start() {
        Log.write("session: start with \(windows.count) window(s): \(windows.map { NSStringFromRect($0.frame) })")
        NSApp.activate(ignoringOtherApps: true)
        for (i, w) in windows.enumerated() {
            w.orderFrontRegardless()
            if i == 0 { w.makeKeyAndOrderFront(nil) }
            w.makeFirstResponder(views[i])
        }
        // Make the window under the mouse the key one so keyboard shortcuts go to the right place.
        let mouse = NSEvent.mouseLocation
        if let idx = windows.firstIndex(where: { $0.frame.contains(mouse) }) {
            windows[idx].makeKeyAndOrderFront(nil)
            windows[idx].makeFirstResponder(views[idx])
        }
        NSCursor.crosshair.set()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        Log.write("session: finished")
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        NSApp.deactivate()
        onFinish?()
    }

    private func hideWindows() {
        windows.forEach { $0.orderOut(nil) }
    }

    // MARK: - OverlayViewDelegate

    func overlayViewDidBeginSelection(_ view: OverlayView) {
        for v in views where v !== view { v.clearSelection() }
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
    }

    func overlayView(_ view: OverlayView, copy image: CGImage) {
        CaptureSession.copyToPasteboard(image)
        finish()
    }

    func overlayView(_ view: OverlayView, save image: CGImage) {
        hideWindows()
        let prefs = Preferences.shared
        let panel = NSSavePanel()
        panel.directoryURL = prefs.saveDirectory
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = CaptureSession.defaultFileName(format: prefs.imageFormat)
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [self] response in
            defer { finish() }
            guard response == .OK, let url = panel.url else { return }
            let format: ImageFormat = url.pathExtension.lowercased().hasPrefix("jp") ? .jpeg : .png
            do {
                try CaptureSession.write(image, to: url, format: format)
                prefs.saveDirectory = url.deletingLastPathComponent()
                if prefs.copyAfterSave { CaptureSession.copyToPasteboard(image) }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func overlayViewDidRequestCancel(_ view: OverlayView) {
        finish()
    }

    func overlayView(_ view: OverlayView, pickedWindow window: WindowInfo) {
        finish()
        onPickWindow?(window)
    }

    func overlayView(_ view: OverlayView, startRecording rect: CGRect) {
        guard let index = views.firstIndex(where: { $0 === view }) else { return }
        let screen = screens[index]
        finish()
        onStartRecording?(screen, rect)
    }

    // MARK: - Helpers

    static func copyToPasteboard(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let item = NSPasteboardItem()
        if let png = encode(image, format: .png) { item.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat) throws {
        guard let data = encode(image, format: format) else {
            throw NSError(domain: "LightshotAlt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode image."])
        }
        try data.write(to: url, options: .atomic)
    }

    static func defaultFileName(format: ImageFormat) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(f.string(from: Date())).\(format.fileExtension)"
    }
}

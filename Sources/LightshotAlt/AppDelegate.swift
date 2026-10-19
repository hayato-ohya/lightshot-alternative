import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var recordMenuItem: NSMenuItem!
    private var fullPageMenuItem: NSMenuItem!
    private var fullPageWindows: [FullPagePreviewWindow] = []
    private var capturingFullPage = false
    private var session: CaptureSession?
    private var preferencesController: PreferencesWindowController?
    private var capturing = false

    private var recorder: ScreenRecorder?
    private var dimWindow: RecordingDimWindow?
    private var recordingTimer: Timer?
    private var startingRecording = false
    private var stoppingRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch: \(Bundle.main.bundlePath) permission=\(ScreenCapturer.hasPermission)")
        buildStatusItem()
        HotKeyManager.shared.onPressed = { [weak self] id in
            switch id {
            case .screenshot: self?.startCapture()
            case .recording: self?.toggleRecording()
            case .stopRecording: self?.stopRecording()
            case .fullPage: self?.startFullPageCapture()
            }
        }
        HotKeyManager.shared.onRegistrationFailed = { [weak self] id, hk, status in self?.showHotKeyFailure(id, hk, status: status) }
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: Preferences.hotKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        if !ScreenCapturer.hasPermission {
            ScreenCapturer.requestPermission()
        }
        if let seconds = selfTestSeconds() { runRecordingSelfTest(seconds: seconds) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        HotKeyManager.shared.ensureRegistered()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        Task { @MainActor in
            _ = try? await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status item & menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        showIdleStatusIcon()

        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "Take Screenshot", action: #selector(captureFromMenu), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)
        recordMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)
        fullPageMenuItem = NSMenuItem(title: "Capture Full Web Page", action: #selector(fullPageFromMenu), keyEquivalent: "")
        fullPageMenuItem.target = self
        menu.addItem(fullPageMenuItem)

        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let aboutItem = NSMenuItem(title: "About Lightshot Alternative", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        HotKeyManager.shared.ensureRegistered()
        let prefs = Preferences.shared
        captureMenuItem.title = "Take Screenshot  (\(prefs.hotKey.displayString))"
        recordMenuItem.title = (recorder != nil ? "Stop Recording" : "Start Recording") + "  (\(prefs.recordingHotKey.displayString))"
        fullPageMenuItem.title = "Capture Full Web Page  (\(prefs.fullPageHotKey.displayString))"
    }

    private func showIdleStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lightshot Alternative")
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
    }

    private func showRecordingStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        updateRecordingTime()
    }

    private func updateRecordingTime() {
        guard let button = statusItem.button, let started = recorder?.startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(started))
        button.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        let prefs = Preferences.shared
        HotKeyManager.shared.register(prefs.hotKey, for: .screenshot)
        HotKeyManager.shared.register(prefs.recordingHotKey, for: .recording)
        HotKeyManager.shared.register(prefs.fullPageHotKey, for: .fullPage)
    }

    private func showHotKeyFailure(_ id: HotKeyManager.ID, _ hk: HotKey, status: OSStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not register shortcut \(hk.displayString)"
        alert.informativeText = "It may already be used by another app or the system (error \(status)). Choose a different shortcut in Preferences."
        alert.addButton(withTitle: "Open Preferences")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { showPreferences() }
    }

    // MARK: - Screenshot

    @objc private func captureFromMenu() {
        // Give the status menu a moment to close so it is not in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.startCapture() }
    }

    func startCapture() {
        Log.write("startCapture: session=\(session == nil ? "nil" : "active") capturing=\(capturing)")
        guard session == nil, !capturing else { return }
        guard ScreenCapturer.hasPermission else {
            Log.write("startCapture: no screen recording permission")
            ScreenCapturer.requestPermission()
            showPermissionAlert()
            return
        }
        beginOverlay(mode: .screenshot) { _ in }
    }

    /// Captures all screens and shows the overlay; `onRecord` fires only in recording mode.
    private func beginOverlay(mode: OverlayView.Mode, onRecord: @escaping ((NSScreen, CGRect)) -> Void) {
        capturing = true
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.capturing else { return }
            Log.write("capture watchdog fired: capture did not finish in time")
            self.capturing = false
            let alert = NSAlert()
            alert.messageText = "Screen capture timed out"
            alert.informativeText = "ScreenCaptureKit did not return an image. Please try again; if it keeps happening, relaunch the app."
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        Task { @MainActor [self] in
            defer { capturing = false; watchdog.cancel() }
            do {
                Log.write("capture: starting")
                let result = try await ScreenCapturer.captureAllScreens()
                Log.write("capture: got \(result.shots.count) screen(s)")
                let session = CaptureSession(result: result, mode: mode)
                session.onFinish = { [weak self] in self?.session = nil }
                session.onStartRecording = { screen, rect in onRecord((screen, rect)) }
                self.session = session
                session.start()
            } catch CaptureError.permissionDenied {
                Log.write("capture: permission denied")
                showPermissionAlert()
            } catch {
                Log.write("capture: error \(error)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = "Lightshot Alternative needs Screen Recording access to take screenshots.\n\nEnable it in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Full page

    @objc private func fullPageFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.startFullPageCapture() }
    }

    func startFullPageCapture() {
        guard session == nil, !capturing, !capturingFullPage, recorder == nil else { return }
        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            showPermissionAlert()
            return
        }
        beginOverlay(mode: .windowPick) { _ in }
        session?.onPickWindow = { [weak self] window in self?.captureFullPage(of: window) }
    }

    private func captureFullPage(of window: WindowInfo) {
        let capturer: FullPageCapturer
        do {
            capturer = try FullPageCapturer(window: window)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
            return
        }
        capturingFullPage = true
        capturer.onProgress = { [weak self] done, total in
            self?.statusItem.button?.title = " \(done)/\(total)"
            self?.statusItem.button?.imagePosition = .imageLeading
        }
        Task { @MainActor [self] in
            defer {
                capturingFullPage = false
                showIdleStatusIcon()
            }
            do {
                Log.write("fullpage: capturing \(window.appName) \"\(window.title)\"")
                let image = try await capturer.capture()
                Log.write("fullpage: done \(image.width)x\(image.height)")
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let preview = FullPagePreviewWindow(image: image, title: window.title, scale: scale)
                fullPageWindows.append(preview)
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: preview, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.fullPageWindows.removeAll { $0 === note.object as? NSWindow } }
                }
                NSApp.activate(ignoringOtherApps: true)
                preview.makeKeyAndOrderFront(nil)
            } catch {
                Log.write("fullpage: failed \(error)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(error: error)
                alert.messageText = "Full-page capture failed"
                alert.runModal()
            }
        }
    }

    // MARK: - Recording

    @objc private func toggleRecordingFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.toggleRecording() }
    }

    func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard session == nil, !capturing, !startingRecording, !stoppingRecording else { return }
        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            showPermissionAlert()
            return
        }
        let options = Preferences.shared.recordingOptions
        beginOverlay(mode: .recording) { [weak self] screen, rect in
            self?.beginRecording(options: options, screen: screen, rect: rect)
        }
    }

    private func recordingURL(for options: RecordingOptions) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording " + f.string(from: Date())
        let ext = "mp4"
        let directory = Preferences.shared.askWhereToSaveRecording
            ? FileManager.default.temporaryDirectory
            : Preferences.shared.saveDirectory
        return directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    private func beginRecording(options: RecordingOptions, screen: NSScreen, rect: CGRect) {
        guard recorder == nil, !startingRecording else { return }
        startingRecording = true
        let recorder = ScreenRecorder(options: options, outputURL: recordingURL(for: options))
        Task { @MainActor [self] in
            defer { startingRecording = false }
            do {
                Log.write("recording: starting \(options) screen=\(screen.localizedName) rect=\(NSStringFromRect(rect))")
                try await recorder.start(screen: screen, rect: rect)
                self.recorder = recorder
                dimWindow = RecordingDimWindow(screen: screen, rect: rect)
                dimWindow?.orderFrontRegardless()
                // Esc stops the recording from any app while it is running.
                HotKeyManager.shared.register(HotKey(keyCode: 53, modifiers: []), for: .stopRecording)
                recorder.onStreamStopped = { [weak self] error in
                    Log.write("recording: stream stopped with error \(String(describing: error))")
                    self?.stopRecording()
                }
                showRecordingStatusIcon()
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRecordingTime() }
                }
            } catch {
                Log.write("recording: failed to start \(error)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(error: error)
                alert.messageText = "Could not start recording"
                alert.runModal()
            }
        }
    }

    private func stopRecording() {
        guard let recorder, !stoppingRecording else { return }
        stoppingRecording = true
        recordingTimer?.invalidate()
        recordingTimer = nil
        self.recorder = nil
        HotKeyManager.shared.remove(.stopRecording)
        dimWindow?.close()
        dimWindow = nil
        showIdleStatusIcon()
        Task { @MainActor [self] in
            defer { stoppingRecording = false }
            do {
                let url = try await recorder.stop()
                Log.write("recording: saved \(url.path)")
                if Preferences.shared.askWhereToSaveRecording {
                    moveWithSavePanel(url)
                }
            } catch {
                Log.write("recording: stop failed \(error)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(error: error)
                alert.messageText = "Recording could not be saved"
                alert.runModal()
            }
        }
    }

    private func moveWithSavePanel(_ url: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .movie]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: url, to: destination)
                Preferences.shared.saveDirectory = destination.deletingLastPathComponent()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Self test (development aid)

    /// `--selftest-record <seconds>` records the main display with system audio for a few seconds,
    /// prints the output path, and quits. Used to verify the pipeline without manual interaction.
    private func selfTestSeconds() -> Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest-record"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    private func runRecordingSelfTest(seconds: Int) {
        let args = CommandLine.arguments
        let source = args.firstIndex(of: "--audio").flatMap { i in i + 1 < args.count ? AudioSource(rawValue: args[i + 1]) : nil } ?? .system
        let options = RecordingOptions(audioSource: source, showCursor: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.mp4")
        let recorder = ScreenRecorder(options: options, outputURL: url)
        Task { @MainActor in
            do {
                let screen = NSScreen.screens[0]
                try await recorder.start(screen: screen, rect: CGRect(x: 100, y: 100, width: 640, height: 400))
                try await Task.sleep(for: .seconds(seconds))
                let out = try await recorder.stop()
                print("SELFTEST OK \(out.path)")
            } catch {
                print("SELFTEST FAILED \(error)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Misc

    @objc func showPreferences() {
        if preferencesController == nil { preferencesController = PreferencesWindowController() }
        preferencesController?.showWindow(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let prefs = Preferences.shared
        let alert = NSAlert()
        alert.messageText = "Lightshot Alternative \(version)"
        alert.informativeText = "A native Apple Silicon screenshot & screen recording tool.\n\nScreenshot: \(prefs.hotKey.displayString)   Recording: \(prefs.recordingHotKey.displayString)\nDrag to select · ⌘C copy · ⌘S save · ⌘Z undo · Esc cancel"
        alert.runModal()
    }
}

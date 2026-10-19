import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var session: CaptureSession?
    private var preferencesController: PreferencesWindowController?
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch: \(Bundle.main.bundlePath) permission=\(ScreenCapturer.hasPermission)")
        buildStatusItem()
        HotKeyManager.shared.onPressed = { [weak self] in self?.startCapture() }
        HotKeyManager.shared.onRegistrationFailed = { [weak self] hk, status in self?.showHotKeyFailure(hk, status: status) }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: Preferences.hotKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
        if !ScreenCapturer.hasPermission {
            ScreenCapturer.requestPermission()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        HotKeyManager.shared.ensureRegistered()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lightshot Alternative")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "Take Screenshot", action: #selector(captureFromMenu), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)
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

    private func registerHotKey() {
        let hk = Preferences.shared.hotKey
        captureMenuItem.title = "Take Screenshot  (\(hk.displayString))"
        HotKeyManager.shared.register(hk)
    }

    private func showHotKeyFailure(_ hk: HotKey, status: OSStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not register shortcut \(hk.displayString)"
        alert.informativeText = "It may already be used by another app or the system (error \(status)). Choose a different shortcut in Preferences."
        alert.addButton(withTitle: "Open Preferences")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { showPreferences() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        HotKeyManager.shared.ensureRegistered()
    }

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
                let session = CaptureSession(result: result)
                session.onFinish = { [weak self] in self?.session = nil }
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

    @objc func showPreferences() {
        if preferencesController == nil { preferencesController = PreferencesWindowController() }
        preferencesController?.showWindow(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = "Lightshot Alternative \(version)"
        alert.informativeText = "A native Apple Silicon screenshot tool.\n\nShortcut: \(Preferences.shared.hotKey.displayString)\nDrag to select · ⌘C copy · ⌘S save · ⌘Z undo · Esc cancel"
        alert.runModal()
    }
}

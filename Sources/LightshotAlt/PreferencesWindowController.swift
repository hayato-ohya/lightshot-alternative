import AppKit
import ServiceManagement

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let prefs = Preferences.shared
    private var recorder: HotKeyRecorderView!
    private var pathLabel: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var copyAfterSaveCheck: NSButton!
    private var loginCheck: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lightshot Alternative Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        recorder = HotKeyRecorderView(hotKey: prefs.hotKey)
        recorder.onChange = { [prefs] hk in prefs.hotKey = hk }
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetHotKey))
        resetButton.bezelStyle = .rounded
        let hotKeyRow = NSStackView(views: [recorder, resetButton])
        hotKeyRow.spacing = 8

        pathLabel = NSTextField(labelWithString: prefs.saveDirectory.path)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [pathLabel, chooseButton])
        folderRow.spacing = 8

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in ImageFormat.allCases { formatPopup.addItem(withTitle: f.title) }
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: prefs.imageFormat) ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        copyAfterSaveCheck = NSButton(checkboxWithTitle: "Also copy to clipboard when saving", target: self, action: #selector(toggleCopyAfterSave))
        copyAfterSaveCheck.state = prefs.copyAfterSave ? .on : .off
        loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLogin))
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Shortcut:"), hotKeyRow],
            [label("Save to:"), folderRow],
            [label("Format:"), formatPopup],
            [NSGridCell.emptyContentView, copyAfterSaveCheck],
            [NSGridCell.emptyContentView, loginCheck],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil) // ends shortcut recording, which resumes the hot key
        HotKeyManager.shared.resume()
    }

    override func showWindow(_ sender: Any?) {
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        recorder.hotKey = prefs.hotKey
        pathLabel.stringValue = prefs.saveDirectory.path
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func resetHotKey() {
        prefs.hotKey = .default
        recorder.hotKey = .default
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveDirectory
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window!) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            prefs.saveDirectory = url
            pathLabel.stringValue = url.path
        }
    }

    @objc private func formatChanged() {
        prefs.imageFormat = ImageFormat.allCases[formatPopup.indexOfSelectedItem]
    }

    @objc private func toggleCopyAfterSave() {
        prefs.copyAfterSave = copyAfterSaveCheck.state == .on
    }

    @objc private func toggleLogin() {
        do {
            if loginCheck.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.informativeText = "Launch at login requires the app to be installed in /Applications and run from the .app bundle."
            alert.beginSheetModal(for: window!)
        }
    }
}

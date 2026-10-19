import AppKit
import Carbon

/// Registers a system-wide hot key via the Carbon HIToolbox API.
/// This works on Apple Silicon and needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPressed: (() -> Void)?
    /// Called when registration keeps failing (e.g. the combo is taken by another app).
    var onRegistrationFailed: ((HotKey, OSStatus) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: HotKey?
    private var paused = false
    private var retryWork: DispatchWorkItem?

    var isRegistered: Bool { hotKeyRef != nil }

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                Log.write("HotKey pressed")
                manager.onPressed?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Registers `hotKey`, retrying for a few seconds if another process (e.g. a previous
    /// instance of this app that is still shutting down) currently holds the same combination.
    func register(_ hotKey: HotKey) {
        unregister()
        current = hotKey
        guard !paused else { return }
        attemptRegister(hotKey, remainingRetries: 10)
    }

    private func attemptRegister(_ hotKey: HotKey, remainingRetries: Int) {
        guard current == hotKey, !paused, hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4C53_4854), id: 1) // "LSHT"
        let status = RegisterEventHotKey(UInt32(hotKey.keyCode), hotKey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            Log.write("HotKey registered: \(hotKey.displayString)")
            return
        }
        hotKeyRef = nil
        Log.write("HotKey registration failed (\(status)) for \(hotKey.displayString), retries left: \(remainingRetries)")
        if remainingRetries > 0 {
            let work = DispatchWorkItem { [weak self] in self?.attemptRegister(hotKey, remainingRetries: remainingRetries - 1) }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            onRegistrationFailed?(hotKey, status)
        }
    }

    func unregister() {
        retryWork?.cancel()
        retryWork = nil
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Re-registers if the hot key was lost for any reason (safety net, cheap to call).
    func ensureRegistered() {
        guard !paused, hotKeyRef == nil, retryWork == nil, let current else { return }
        attemptRegister(current, remainingRetries: 3)
    }

    /// Temporarily disables the hot key (used while recording a new shortcut).
    func pause() {
        paused = true
        unregister()
    }

    func resume() {
        guard paused else { return }
        paused = false
        if let current { register(current) }
    }
}

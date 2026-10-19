import AppKit
import Carbon

/// Registers system-wide hot keys via the Carbon HIToolbox API.
/// This works on Apple Silicon and needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum ID: UInt32 {
        case screenshot = 1
        case recording = 2
        case stopRecording = 3
        case fullPage = 4
    }

    var onPressed: ((ID) -> Void)?
    /// Called when registration keeps failing (e.g. the combo is taken by another app).
    var onRegistrationFailed: ((ID, HotKey, OSStatus) -> Void)?

    private var refs: [ID: EventHotKeyRef] = [:]
    private var current: [ID: HotKey] = [:]
    private var retries: [ID: DispatchWorkItem] = [:]
    private var handlerRef: EventHandlerRef?
    private var paused = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let id = ID(rawValue: hotKeyID.id) else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                Log.write("HotKey pressed: \(id)")
                manager.onPressed?(id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Registers `hotKey` for `id`, retrying for a few seconds if another process (e.g. a previous
    /// instance of this app that is still shutting down) currently holds the same combination.
    func register(_ hotKey: HotKey, for id: ID) {
        unregister(id)
        current[id] = hotKey
        guard !paused else { return }
        attemptRegister(hotKey, id: id, remainingRetries: 10)
    }

    private func attemptRegister(_ hotKey: HotKey, id: ID, remainingRetries: Int) {
        guard current[id] == hotKey, !paused, refs[id] == nil else { return }
        let carbonID = EventHotKeyID(signature: OSType(0x4C53_4854), id: id.rawValue) // "LSHT"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(hotKey.keyCode), hotKey.carbonModifiers, carbonID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            Log.write("HotKey registered: \(id) = \(hotKey.displayString)")
            return
        }
        Log.write("HotKey registration failed (\(status)) for \(id) = \(hotKey.displayString), retries left: \(remainingRetries)")
        if remainingRetries > 0 {
            let work = DispatchWorkItem { [weak self] in self?.attemptRegister(hotKey, id: id, remainingRetries: remainingRetries - 1) }
            retries[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            onRegistrationFailed?(id, hotKey, status)
        }
    }

    /// Unregisters `id` and forgets it, so it is not restored by `resume` or `ensureRegistered`.
    func remove(_ id: ID) {
        unregister(id)
        current[id] = nil
    }

    func unregister(_ id: ID) {
        retries[id]?.cancel()
        retries[id] = nil
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
        }
    }

    /// Re-registers any hot key that was lost for some reason (safety net, cheap to call).
    func ensureRegistered() {
        guard !paused else { return }
        for (id, hotKey) in current where refs[id] == nil && retries[id] == nil {
            attemptRegister(hotKey, id: id, remainingRetries: 3)
        }
    }

    /// Temporarily disables all hot keys (used while recording a new shortcut).
    func pause() {
        paused = true
        for id in Array(refs.keys) + Array(retries.keys) { unregister(id) }
    }

    func resume() {
        guard paused else { return }
        paused = false
        for (id, hotKey) in current { register(hotKey, for: id) }
    }
}

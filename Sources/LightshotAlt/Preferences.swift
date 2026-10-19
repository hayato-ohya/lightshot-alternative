import AppKit
import Carbon

struct HotKey: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let `default` = HotKey(keyCode: 25 /* 9 */, modifiers: [.command, .shift])

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + HotKey.keyName(for: keyCode)
    }

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static func keyName(for keyCode: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↑", 126: "↓",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let s = special[keyCode] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            UCKeyTranslate(ptr.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                           keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum ImageFormat: String, CaseIterable {
    case png, jpeg
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

final class Preferences {
    static let shared = Preferences()
    static let hotKeyDidChange = Notification.Name("PreferencesHotKeyDidChange")

    private let defaults = UserDefaults.standard
    private enum Key {
        static let keyCode = "hotKeyCode"
        static let modifiers = "hotKeyModifiers"
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let copyAfterSave = "copyAfterSave"
    }

    var hotKey: HotKey {
        get {
            guard defaults.object(forKey: Key.keyCode) != nil else { return .default }
            return HotKey(keyCode: UInt16(defaults.integer(forKey: Key.keyCode)),
                          modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Key.modifiers))))
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.keyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.modifiers)
            NotificationCenter.default.post(name: Preferences.hotKeyDidChange, object: nil)
        }
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.saveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: Key.saveDirectory) }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: Key.imageFormat) ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.imageFormat) }
    }

    var copyAfterSave: Bool {
        get { defaults.bool(forKey: Key.copyAfterSave) }
        set { defaults.set(newValue, forKey: Key.copyAfterSave) }
    }
}

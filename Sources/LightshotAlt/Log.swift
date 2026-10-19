import Foundation

/// Optional diagnostics. Disabled by default; enable with
///   defaults write com.hayato.lightshot-alternative debugLogging -bool true
/// and relaunch. Lines go to ~/Library/Logs/Lightshot Alternative.log and the unified log.
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lightshot Alternative.log")
    static let isEnabled = UserDefaults.standard.bool(forKey: "debugLogging")

    private static let queue = DispatchQueue(label: "LightshotAlt.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        NSLog("%@", text)
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(text)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL)
            }
        }
    }
}

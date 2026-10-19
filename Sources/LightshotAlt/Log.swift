import Foundation

/// Appends diagnostics to ~/Library/Logs/Lightshot Alternative.log (and the unified log).
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lightshot Alternative.log")
    private static let queue = DispatchQueue(label: "LightshotAlt.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("%@", message)
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
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

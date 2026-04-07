import Foundation

enum DebugTrace {
#if DEBUG
    private static let queue = DispatchQueue(label: "com.octodot.debug-trace")
    static let logURL = URL(fileURLWithPath: "/tmp/octodot-debug-trace.log")
    private static let maxLogSize: UInt64 = 2 * 1024 * 1024 // 2 MB

    static func reset() {
        queue.sync {
            rotateIfNeeded()
            let header = "\n========== Session \(ISO8601DateFormatter().string(from: Date())) ==========\n"
            if let data = header.data(using: .utf8) {
                appendData(data)
            }
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            appendData(data)
        }
    }

    private static func appendData(_ data: Data) {
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let previousURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("octodot-debug-trace.prev.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
    }
#else
    static let logURL = URL(fileURLWithPath: "/dev/null")
    static func reset() {}
    static func log(_ message: @autoclosure () -> String) {}
#endif
}

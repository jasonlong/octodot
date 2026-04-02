import Foundation

enum DebugTrace {
#if DEBUG
    private static let queue = DispatchQueue(label: "com.octodot.debug-trace")
    static let logURL = URL(fileURLWithPath: "/tmp/octodot-debug-trace.log")

    static func reset() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
            let header = "[Octodot debug trace started]\n"
            try? header.data(using: .utf8)?.write(to: logURL, options: .atomic)
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }
#else
    static let logURL = URL(fileURLWithPath: "/dev/null")
    static func reset() {}
    static func log(_ message: @autoclosure () -> String) {}
#endif
}

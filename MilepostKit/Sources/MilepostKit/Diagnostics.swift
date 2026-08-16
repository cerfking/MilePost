import Foundation
import os

/// Appends a line to `Documents/carplay-diagnostics.txt`.
///
/// `os_log` is the right tool, but a CarPlay scene is launched by the car
/// rather than the debugger, so no console is attached and its output cannot be
/// read off a tethered device from a script. A file in the app container can be
/// pulled with `devicectl device copy from`, which is what makes the CarPlay
/// connection and playback sequence observable at all.
public enum Diagnostics {
    nonisolated private static let log = Logger(subsystem: "com.cerf.Milepost", category: "Diagnostics")

    nonisolated public static func write(_ line: String) {
        log.info("\(line, privacy: .public)")
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        let url = dir.appendingPathComponent("carplay-diagnostics.txt")
        guard let data = "\(Date().formatted(.iso8601)) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

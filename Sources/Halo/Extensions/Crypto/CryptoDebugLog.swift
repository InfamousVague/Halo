import Foundation

// MARK: - File log for diagnostics

/// Append-only log at `/tmp/halo-crypto.log` so the user
/// can `tail -f` it without fighting `log show` filtering.
/// Truncates to 128KB so a long session doesn't grow the
/// file forever.
enum CryptoDebugLog {
    nonisolated(unsafe) private static var didTruncate = false
    private static let path = "/tmp/halo-crypto.log"

    static func append(_ line: String) {
        if !didTruncate {
            try? "".write(toFile: path, atomically: true,
                          encoding: .utf8)
            didTruncate = true
        }
        let stamped = "\(Date()) \(line)\n"
        guard let handle = FileHandle(forWritingAtPath: path),
              let data = stamped.data(using: .utf8)
        else { return }
        handle.seekToEndOfFile()
        if handle.offsetInFile > 128_000 {
            try? handle.close()
            try? "".write(toFile: path, atomically: true,
                          encoding: .utf8)
            if let h2 = FileHandle(
                forWritingAtPath: path) {
                try? h2.write(contentsOf: data)
                try? h2.close()
            }
            return
        }
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}


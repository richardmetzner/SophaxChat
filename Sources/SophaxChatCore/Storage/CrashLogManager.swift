// CrashLogManager.swift
// SophaxChatCore
//
// On-device, privacy-respecting error log.
// Never logs message content or peer identifiers — only error types and context strings.
// Users can view and voluntarily export the log from Settings when filing a bug report.

import Foundation

public final class CrashLogManager: @unchecked Sendable {

    public static let shared = CrashLogManager()

    private let logFile: URL
    private let queue   = DispatchQueue(label: "com.sophax.crashlog", qos: .utility)

    private static let maxLines      = 200
    private static let maxFileSizeB  = 512_000  // 512 KB safety cap

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("sophax_crash_logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFile = dir.appendingPathComponent("crash_log.txt")
    }

    // MARK: - Public API

    /// Log an error with a context label (e.g. "X3DH", "BackupRestore").
    /// Only the error *type* is recorded — message content is never logged.
    public func log(_ error: Error, context: String) {
        let typeName = String(reflecting: type(of: error))
        let description = error.localizedDescription
        // Strip anything that looks like a peer ID (hex strings ≥ 16 chars)
        let sanitized = sanitize(description)
        append("[ERROR] [\(context)] \(typeName): \(sanitized)")
    }

    /// Log a plain diagnostic string (must never contain message content or peer IDs).
    public func log(_ message: String, context: String) {
        append("[\(context)] \(message)")
    }

    /// Returns all log entries as a single string for display or export.
    public func exportableText() -> String {
        queue.sync {
            (try? String(contentsOf: logFile, encoding: .utf8)) ?? "(no log entries)"
        }
    }

    /// Delete all log entries.
    public func clear() {
        queue.async { [logFile] in
            try? FileManager.default.removeItem(at: logFile)
        }
    }

    // MARK: - Private

    private func append(_ body: String) {
        let timestamp = Self.iso8601.string(from: Date())
        let line      = "[\(timestamp)] \(body)\n"
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    private func write(_ line: String) {
        // Append to file
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile, options: .atomic)
            }
        }
        rotate()
    }

    /// Keep the file under maxLines and maxFileSizeB.
    private func rotate() {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        // Remove empty trailing element from split
        if lines.last == "" { lines.removeLast() }

        let oversizedFile = (text.utf8.count > Self.maxFileSizeB)
        let tooManyLines  = (lines.count > Self.maxLines)

        guard oversizedFile || tooManyLines else { return }

        // Drop oldest half
        let keep = lines.suffix(Self.maxLines / 2)
        let trimmed = keep.joined(separator: "\n") + "\n"
        try? trimmed.write(to: logFile, atomically: true, encoding: .utf8)
    }

    /// Remove long hex-looking substrings that could be peer IDs.
    private func sanitize(_ input: String) -> String {
        // Replace hex sequences of 16+ chars with <redacted>
        let pattern = "[0-9a-fA-F]{16,}"
        return (try? NSRegularExpression(pattern: pattern))
            .map { $0.stringByReplacingMatches(in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "<redacted>") }
            ?? input
    }
}

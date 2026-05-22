import Darwin
import Foundation
import os

/// Lightweight rolling logger. Writes to ~/Library/Application Support/Nazar/nazar.log
/// and mirrors to os_log so it shows up in Console.app under subsystem "app.nazar".
final class Logger {
    static let shared = Logger()

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    private let osLog = OSLog(subsystem: "app.nazar", category: "general")
    private let queue = DispatchQueue(label: "app.nazar.logger", qos: .utility)
    private let maxBytes: Int = 256 * 1024 // 256 KB — small enough to attach to feedback

    private(set) lazy var logURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Nazar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nazar.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func info(_ message: String)  { write(.info,  message) }
    func warn(_ message: String)  { write(.warn,  message) }
    func error(_ message: String) { write(.error, message) }

    /// Returns the last N bytes of the log as text. Used by the feedback dialog.
    func recentText(maxBytes: Int = 16 * 1024) -> String {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    func clear() {
        queue.sync { try? "".write(to: logURL, atomically: true, encoding: .utf8) }
    }

    private func write(_ level: Level, _ message: String) {
        let line = "[\(Self.formatter.string(from: Date()))] [\(level.rawValue)] \(message)\n"
        os_log("%{public}@", log: osLog, type: level.osLogType, line)

        queue.async { [weak self] in
            guard let self = self else { return }
            guard let data = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            if !fm.fileExists(atPath: self.logURL.path) {
                try? data.write(to: self.logURL)
                return
            }
            if let handle = try? FileHandle(forWritingTo: self.logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
            // Trim if oversized.
            if let attrs = try? fm.attributesOfItem(atPath: self.logURL.path),
               let size = attrs[.size] as? Int, size > self.maxBytes {
                self.trim()
            }
        }
    }

    private func trim() {
        guard let data = try? Data(contentsOf: logURL) else { return }
        let keep = data.suffix(maxBytes / 2)
        try? keep.write(to: logURL)
    }

    // MARK: - Crash handler installation

    /// Installs handlers for Obj-C exceptions and fatal Unix signals (SIGSEGV,
    /// SIGABRT, etc.) so that crashes drop a "CRASH" line into the log before
    /// the process dies. The line is the first thing users see in feedback.
    func installCrashHandlers() {
        // Warm up the lazy logURL so the path string exists before any signal
        // handler tries to read it — string allocation in a signal handler is
        // undefined behavior. We also stash the C-string ahead of time.
        Self.crashPathCString = Logger.shared.logURL.path.cString(using: .utf8)

        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            let line = "CRASH (uncaught NSException): \(exception.name.rawValue) — \(exception.reason ?? "?")\n\(stack)\n"
            Logger.crashFallback(line)
        }
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGPIPE] {
            signal(sig) { sig in
                Logger.crashFallbackSignal(sig)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    /// Pre-allocated buffer for the signal handler — avoids any malloc in
    /// async-signal-unsafe paths during a crash.
    fileprivate static var crashPathCString: [CChar]?

    /// Async-signal-safe variant: no Swift allocations, no Foundation.
    fileprivate static func crashFallbackSignal(_ sig: Int32) {
        guard var path = crashPathCString else { return }
        let fd = path.withUnsafeMutableBufferPointer { buf -> Int32 in
            return Darwin.open(buf.baseAddress!, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else { return }
        // Pre-formatted strings only
        let header = "[CRASH] signal "
        _ = header.withCString { Darwin.write(fd, $0, Darwin.strlen($0)) }
        // Manual integer-to-ascii for `sig` (1-2 digits)
        var s = sig
        var buf: [CChar] = [0, 0, 0, 10, 0] // up to 3 digits + LF + NUL
        var i = 2
        if s == 0 { buf[i] = 0x30 /* '0' */; i -= 1 }
        while s > 0 && i >= 0 { buf[i] = CChar(0x30 + (s % 10)); s /= 10; i -= 1 }
        _ = buf.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!.advanced(by: i + 1), $0.count - (i + 1)) }
        Darwin.close(fd)
    }

    /// Async-signal-safe enough — writes via low-level POSIX so we can be
    /// called from a signal handler. No Foundation queues, no String formatting
    /// beyond what's already happened.
    fileprivate static func crashFallback(_ message: String) {
        let path = Logger.shared.logURL.path
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let stamp = "[CRASH \(Date().timeIntervalSince1970)] "
        _ = stamp.withCString { Darwin.write(fd, $0, Darwin.strlen($0)) }
        _ = message.withCString { Darwin.write(fd, $0, Darwin.strlen($0)) }
        Darwin.close(fd)
    }
}

private extension Logger.Level {
    var osLogType: OSLogType {
        switch self {
        case .info:  return .info
        case .warn:  return .default
        case .error: return .error
        }
    }
}

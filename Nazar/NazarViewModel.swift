import SwiftUI
import Combine

// MARK: - Models

struct RunningApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let app: NSRunningApplication
}

struct DiskUsage {
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }
    var usedRatio: CGFloat { CGFloat(used) / CGFloat(total) }
    var usedFormatted: String { ByteCountFormatter.string(fromByteCount: used, countStyle: .file) }
    var freeFormatted: String { ByteCountFormatter.string(fromByteCount: free, countStyle: .file) }
}

struct CleanableItem: Identifiable {
    let id: String
    let name: String
    let icon: String
    let paths: [String]
    var isCustom: Bool = false
    /// -1 = unknown / still calculating, 0+ = bytes
    var size: Int64 = -1
    var sizeFormatted: String {
        if size < 0 { return "…" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Custom Folders Manager

class CustomFoldersManager {
    static let shared = CustomFoldersManager()
    private let key = "nazar_custom_folders"

    struct CustomFolder: Codable {
        let name: String
        let path: String
    }

    func load() -> [CustomFolder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let folders = try? JSONDecoder().decode([CustomFolder].self, from: data) else { return [] }
        return folders
    }

    func save(_ folders: [CustomFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ folder: CustomFolder) {
        var folders = load()
        folders.append(folder)
        save(folders)
    }

    func remove(at index: Int) {
        var folders = load()
        guard index < folders.count else { return }
        folders.remove(at: index)
        save(folders)
    }
}

struct SystemUpdate: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    let size: String
}

// MARK: - ViewModel

class NazarViewModel: ObservableObject {
    @Published var runningApps: [RunningApp] = []
    @Published var diskUsage: DiskUsage?
    @Published var cleanableItems: [CleanableItem] = []
    @Published var selectedItems: Set<String> = []
    @Published var isOptimizing = false
    @Published var optimizationProgress: Double = 0
    @Published var optimizationStatus = ""
    @Published var availableUpdates: [SystemUpdate] = []
    @Published var isCheckingUpdates = false
    @Published var updatesChecked = false
    @Published var isDownloadingUpdates = false
    @Published var downloadStatus = ""

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: - Running Apps

    /// Pure snapshot — safe to call from any thread.
    func snapshotRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.bundleIdentifier != "com.apple.finder" }
            .map { RunningApp(id: $0.processIdentifier, name: $0.localizedName ?? "Unknown", icon: $0.icon, app: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshRunningApps() {
        let apps = snapshotRunningApps()
        if Thread.isMainThread {
            runningApps = apps
        } else {
            DispatchQueue.main.async { [weak self] in self?.runningApps = apps }
        }
    }

    func closeApp(_ app: RunningApp) {
        app.app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if app.app.isTerminated == false {
                app.app.forceTerminate()
            }
            self?.refreshRunningApps()
        }
    }

    func closeAllApps() {
        let onceList = ProtectedAppsManager.shared.consumeOnce()
        let alwaysList = ProtectedAppsManager.shared.alwaysProtected()
        let protected = Set(alwaysList + onceList)

        let appsToClose = snapshotRunningApps().filter { app in
            guard let bundleID = app.app.bundleIdentifier else { return true }
            return !protected.contains(bundleID)
        }

        for app in appsToClose { app.app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            for app in appsToClose where !app.app.isTerminated {
                app.app.forceTerminate()
            }
            self?.refreshRunningApps()
        }
    }

    /// Synchronous variant for the cleanup pipeline. Returns
    /// (closed, stillRunning, protected, newlyLaunched). `newlyLaunched`
    /// captures apps that started up during the close window — caller can
    /// decide whether to do a follow-up pass.
    func closeAllAppsAndWait(timeout: TimeInterval = 2.0) -> (closed: [RunningApp], stillRunning: [RunningApp], protected: [RunningApp], newlyLaunched: [RunningApp]) {
        let onceList = ProtectedAppsManager.shared.consumeOnce()
        let alwaysList = ProtectedAppsManager.shared.alwaysProtected()
        let protectedIDs = Set(alwaysList + onceList)

        let snapshot = snapshotRunningApps()
        let originalPIDs = Set(snapshot.map(\.id))
        let protected = snapshot.filter { protectedIDs.contains($0.app.bundleIdentifier ?? "") }
        var toClose = snapshot.filter { !protectedIDs.contains($0.app.bundleIdentifier ?? "") }

        for app in toClose { app.app.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if toClose.allSatisfy({ $0.app.isTerminated }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for app in toClose where !app.app.isTerminated { app.app.forceTerminate() }
        Thread.sleep(forTimeInterval: 0.3)

        // Second pass: anyone unprotected who launched during the wait gets
        // terminated too, with a shorter timeout.
        let post = snapshotRunningApps()
        let newlyLaunched = post.filter {
            !originalPIDs.contains($0.id) && !protectedIDs.contains($0.app.bundleIdentifier ?? "")
        }
        for app in newlyLaunched { app.app.terminate() }
        if !newlyLaunched.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
            for app in newlyLaunched where !app.app.isTerminated { app.app.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        toClose.append(contentsOf: newlyLaunched)

        let stillRunning = toClose.filter { !$0.app.isTerminated }
        let closed = toClose.filter { $0.app.isTerminated }
        return (closed, stillRunning, protected, newlyLaunched)
    }

    // MARK: - System Updates

    func checkForUpdates() {
        isCheckingUpdates = true
        updatesChecked = false
        availableUpdates = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            task.arguments = ["-l"]
            task.standardOutput = pipe
            task.standardError = pipe
            try? task.run()
            task.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            var updates: [SystemUpdate] = []
            let lines = output.components(separatedBy: "\n")

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("* Label:") {
                    let name = trimmed.replacingOccurrences(of: "* Label: ", with: "")

                    // Next line usually has version/size info
                    var version = ""
                    var size = ""
                    if i + 1 < lines.count {
                        let detail = lines[i + 1]
                        // Parse "Title: ..., Version: ..., Size: ...,"
                        if let vRange = detail.range(of: "Version: ") {
                            let afterV = detail[vRange.upperBound...]
                            version = String(afterV.prefix(while: { $0 != "," }))
                        }
                        if let sRange = detail.range(of: "Size: ") {
                            let afterS = detail[sRange.upperBound...]
                            size = String(afterS.prefix(while: { $0 != "," }))
                        }
                    }

                    updates.append(SystemUpdate(name: name, version: version, size: size))
                }
            }

            DispatchQueue.main.async {
                self?.availableUpdates = updates
                self?.isCheckingUpdates = false
                self?.updatesChecked = true
            }
        }
    }

    func downloadUpdates() {
        isDownloadingUpdates = true
        downloadStatus = "Downloading..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            task.arguments = ["-d", "-a", "--agree-to-license"]
            task.standardOutput = pipe
            task.standardError = pipe
            try? task.run()
            task.waitUntilExit()

            let success = task.terminationStatus == 0

            DispatchQueue.main.async {
                self?.isDownloadingUpdates = false
                self?.downloadStatus = success ? "Downloaded — open Software Update to install" : "Download failed"
            }
        }
    }

    // MARK: - Disk

    /// Refreshes disk size info. Cheap parts (free space, item shells) update
    /// immediately on the calling (main) thread so the dashboard can render
    /// instantly; the slow per-folder enumeration runs on a background queue
    /// and pushes updated sizes back to @Published once each item finishes.
    func calculateDiskUsage() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let total = (attrs[.systemSize] as? Int64) ?? 0
            let free = (attrs[.systemFreeSize] as? Int64) ?? 0
            diskUsage = DiskUsage(total: total, free: free)
        }

        let dlFilter = AgeFilter.currentDownloads
        let dlLabel = dlFilter == .all ? "Downloads (All)" : "Downloads (\(dlFilter.label.lowercased()))"

        let builtIn: [(String, String, String, [String])] = [
            ("caches", "User Caches", "archivebox.fill", ["\(homeDir)/Library/Caches"]),
            ("logs", "System Logs", "doc.text.fill", ["\(homeDir)/Library/Logs", "/private/var/log"]),
            ("trash", "Trash", "trash.fill", ["\(homeDir)/.Trash"]),
            ("downloads", dlLabel, "arrow.down.circle.fill", ["\(homeDir)/Downloads"]),
            ("xcode", "Xcode Derived Data", "hammer.fill", ["\(homeDir)/Library/Developer/Xcode/DerivedData"]),
            ("temp", "Temporary Files", "clock.fill", [NSTemporaryDirectory()]),
        ]

        var shells = builtIn.map { CleanableItem(id: $0.0, name: $0.1, icon: $0.2, paths: $0.3) }
        for (index, folder) in CustomFoldersManager.shared.load().enumerated() {
            let folderId = "custom_\(index)"
            let folderFilter = AgeFilter.forFolder(folderId)
            let suffix = folderFilter == .all ? "" : " (\(folderFilter.label.lowercased()))"
            shells.append(CleanableItem(
                id: folderId, name: folder.name + suffix, icon: "folder.fill",
                paths: [folder.path], isCustom: true
            ))
        }

        cleanableItems = shells

        let dlDays = dlFilter.days
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for shell in shells {
                let size: Int64
                switch shell.id {
                case "trash":
                    size = self.trashSize()
                case "downloads":
                    size = dlDays.map { self.oldFilesSize(at: shell.paths[0], olderThanDays: $0) }
                        ?? self.directorySize(at: shell.paths[0])
                default:
                    if shell.id.hasPrefix("custom_") {
                        let f = AgeFilter.forFolder(shell.id)
                        size = f.days.map { self.oldFilesSize(at: shell.paths[0], olderThanDays: $0) }
                            ?? self.directorySize(at: shell.paths[0])
                    } else {
                        size = shell.paths.reduce(0) { $0 + self.directorySize(at: $1) }
                    }
                }
                DispatchQueue.main.async {
                    guard let idx = self.cleanableItems.firstIndex(where: { $0.id == shell.id }) else { return }
                    self.cleanableItems[idx].size = size
                }
            }
        }
    }

    func addCustomFolder(name: String, path: String) {
        CustomFoldersManager.shared.add(CustomFoldersManager.CustomFolder(name: name, path: path))
        calculateDiskUsage()
    }

    func removeCustomFolder(itemId: String) {
        guard itemId.hasPrefix("custom_"),
              let index = Int(itemId.replacingOccurrences(of: "custom_", with: "")) else { return }
        CustomFoldersManager.shared.remove(at: index)
        selectedItems.remove(itemId)
        calculateDiskUsage()
    }

    func optimizeDisk() {
        guard !selectedItems.isEmpty else { return }
        isOptimizing = true
        optimizationProgress = 0

        let selected = cleanableItems.filter { selectedItems.contains($0.id) }
        let total = selected.count

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for (index, item) in selected.enumerated() {
                DispatchQueue.main.async {
                    self.optimizationStatus = "Cleaning \(item.name)..."
                    self.optimizationProgress = Double(index) / Double(total)
                }

                for path in item.paths {
                    self.cleanDirectory(at: path, itemId: item.id, deleteRoot: false)
                }

                Thread.sleep(forTimeInterval: 0.3)
            }

            DispatchQueue.main.async {
                self.optimizationStatus = "Purging system caches..."
                self.optimizationProgress = 0.95
            }
            self.purgeSystemCaches()

            DispatchQueue.main.async {
                self.optimizationProgress = 1.0
                self.optimizationStatus = "Done!"
                self.selectedItems.removeAll()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.isOptimizing = false
                    self.optimizationProgress = 0
                    self.optimizationStatus = ""
                    self.calculateDiskUsage()
                }
            }
        }
    }

    /// IDs that are too dangerous for automatic one-click cleanup
    static let manualOnlyItems: Set<String> = ["downloads"]

    /// Fast pipeline cleanup — independent of UI state. Reports per-item progress
    /// so the status line stays informative even on slow directories.
    /// Safe to call from a background thread; does NOT touch @Published state.
    func runPipelineCleanup(progress: @escaping (Int, String) -> Void) -> Int64 {
        let freeBefore = currentFreeSpace()

        struct Job { let label: String; let paths: [String]; let itemId: String }
        var jobs: [Job] = [
            Job(label: L.t("status.userCaches"), paths: ["\(homeDir)/Library/Caches"], itemId: "caches"),
            Job(label: L.t("status.systemLogs"), paths: ["\(homeDir)/Library/Logs", "/private/var/log"], itemId: "logs"),
            Job(label: L.t("status.trash"), paths: ["\(homeDir)/.Trash"], itemId: "trash"),
            Job(label: L.t("status.xcode"), paths: ["\(homeDir)/Library/Developer/Xcode/DerivedData"], itemId: "xcode"),
            Job(label: L.t("status.temp"), paths: [NSTemporaryDirectory()], itemId: "temp"),
        ]

        for (i, folder) in CustomFoldersManager.shared.load().enumerated() {
            jobs.append(Job(label: folder.name, paths: [folder.path], itemId: "custom_\(i)"))
        }

        let total = jobs.count + 1
        for (idx, job) in jobs.enumerated() {
            progress(Int(Double(idx) / Double(total) * 100), job.label)
            for p in job.paths {
                cleanDirectory(at: p, itemId: job.itemId, deleteRoot: false)
            }
        }

        progress(Int(Double(jobs.count) / Double(total) * 100), L.t("status.systemCaches"))
        purgeSystemCaches()
        progress(100, L.t("status.done"))

        let freeAfter = currentFreeSpace()
        return max(freeAfter - freeBefore, 0)
    }

    /// Lightweight — does not enumerate any files.
    func currentFreeSpace() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return 0 }
        return (attrs[.systemFreeSize] as? Int64) ?? 0
    }

    // MARK: - Helpers

    private func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            // Skip symlinks to avoid double-counting target sizes or following
            // chains out of the cleanup root.
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               (attrs[.type] as? FileAttributeType) != .typeSymbolicLink,
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    private func trashSize() -> Int64 {
        // Quick size check with timeout — avoids hanging on large trash
        var result: Int64 = 0
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            let pipe = Pipe()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", """
                tell application "Finder"
                    set totalSize to 0
                    repeat with anItem in (items of trash)
                        try
                            set totalSize to totalSize + (size of anItem)
                        end try
                    end repeat
                    return totalSize
            end tell
            """]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()

            // Kill osascript if it takes too long
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 5)
            timer.setEventHandler { if task.isRunning { task.terminate() } }
            timer.resume()

            task.waitUntilExit()
            timer.cancel()

            if task.terminationStatus == 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result = Int64(output) ?? 0
            }
            semaphore.signal()
        }

        // Wait max 6 seconds total, then return 0 (unknown size)
        if semaphore.wait(timeout: .now() + 6) == .timedOut {
            return -1 // will show "Unknown" in UI
        }
        return result
    }

    private func oldFilesSize(at path: String, olderThanDays days: Int) -> Int64 {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        var total: Int64 = 0
        for item in contents {
            let fullPath = (path as NSString).appendingPathComponent(item)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            if let size = attrs[.size] as? Int64 {
                total += size
            }
            // If it's a directory, add its recursive size
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                total += directorySize(at: fullPath)
            }
        }
        return total
    }

    private func cleanDirectory(at path: String, itemId: String = "", deleteRoot: Bool) {
        if path.hasSuffix("/.Trash") {
            emptyTrash()
            return
        }

        // Bail early if path doesn't exist or is unreadable (e.g. /private/var/log
        // without admin) — avoids logging spurious "permission denied" noise.
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) || fm.fileExists(atPath: path) else {
            Logger.shared.warn("cleanDirectory skipped (unreadable): \(path)")
            return
        }

        if itemId == "downloads" {
            if let days = AgeFilter.currentDownloads.days {
                cleanOldFiles(at: path, olderThanDays: days)
            } else {
                guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
                for file in contents { removeSafely(at: (path as NSString).appendingPathComponent(file)) }
            }
            return
        }

        if itemId.hasPrefix("custom_") {
            let folderFilter = AgeFilter.forFolder(itemId)
            if let days = folderFilter.days {
                cleanOldFiles(at: path, olderThanDays: days)
                return
            }
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            Logger.shared.warn("cleanDirectory contentsOfDirectory failed: \(path)")
            return
        }
        for item in contents {
            removeSafely(at: (path as NSString).appendingPathComponent(item))
        }
        if deleteRoot {
            removeSafely(at: path)
        }
    }

    /// Skip symlinks (could escape the cleanup boundary) and report failures
    /// to the log so silent permission denials are visible in feedback bundles.
    private func removeSafely(at fullPath: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: fullPath)
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           vals.isSymbolicLink == true {
            // Unlink the symlink itself, not the target.
            do { try fm.removeItem(at: url) }
            catch { Logger.shared.warn("symlink unlink failed: \(fullPath) — \(error.localizedDescription)") }
            return
        }
        do { try fm.removeItem(atPath: fullPath) }
        catch let err as NSError {
            // EPERM/EACCES are expected for system-protected files — log once but don't spam
            if err.code != NSFileWriteNoPermissionError && err.code != NSFileWriteFileExistsError {
                Logger.shared.warn("remove failed: \(fullPath) — \(err.localizedDescription)")
            }
        }
    }

    private func cleanOldFiles(at path: String, olderThanDays days: Int) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        for item in contents {
            let fullPath = (path as NSString).appendingPathComponent(item)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            removeSafely(at: fullPath)
        }
    }

    /// Empty Trash via Finder; if AppleEvents is denied or Finder isn't running,
    /// fall back to direct FileManager enumeration of ~/.Trash.
    private func emptyTrash() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Finder\" to empty the trash"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            runProcessWithTimeout(task, seconds: 15)
            if task.terminationStatus == 0 { return }
            Logger.shared.warn("Finder emptyTrash failed (status=\(task.terminationStatus)), falling back")
        } catch {
            Logger.shared.warn("osascript launch failed: \(error.localizedDescription), falling back")
        }

        // Fallback: enumerate ~/.Trash and remove each entry directly.
        let fm = FileManager.default
        let trash = "\(homeDir)/.Trash"
        guard let entries = try? fm.contentsOfDirectory(atPath: trash) else { return }
        for entry in entries {
            removeSafely(at: (trash as NSString).appendingPathComponent(entry))
        }
    }

    /// `purge` flushes the disk cache; on macOS it works without admin only on
    /// some builds. Treat non-zero exit as a soft warning, not an error.
    private func purgeSystemCaches() {
        let purgeURL = URL(fileURLWithPath: "/usr/bin/purge")
        guard FileManager.default.fileExists(atPath: purgeURL.path) else {
            Logger.shared.warn("purge binary not present — skipping")
            return
        }
        let task = Process()
        task.executableURL = purgeURL
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            runProcessWithTimeout(task, seconds: 10)
            if task.terminationStatus != 0 {
                Logger.shared.warn("purge exited non-zero (status=\(task.terminationStatus)) — likely needs admin")
            }
        } catch {
            Logger.shared.warn("purge launch failed: \(error.localizedDescription)")
        }
    }

    private func runProcessWithTimeout(_ task: Process, seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { if task.isRunning { task.terminate() } }
        timer.resume()
        task.waitUntilExit()
        timer.cancel()
    }
}

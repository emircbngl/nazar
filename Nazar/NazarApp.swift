import SwiftUI
import Carbon
import UserNotifications

@main
struct NazarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Trigger Mode

enum TriggerMode: String, CaseIterable {
    case doubleTouch = "double_touch"
    case doubleClick = "double_click"
    case optionClick = "option_click"
    case longPress   = "long_press"

    var label: String {
        switch self {
        case .doubleTouch: return "Double Touch (tap)"
        case .doubleClick: return "Double Click (press)"
        case .optionClick: return "⌥ Option + Click"
        case .longPress:   return "Long Press (1s)"
        }
    }

    var hint: String {
        switch self {
        case .doubleTouch: return "Double-tap the trackpad"
        case .doubleClick: return "Double-click (press down)"
        case .optionClick: return "Hold ⌥ and click"
        case .longPress:   return "Press and hold for 1 second"
        }
    }

    static var current: TriggerMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "nazar_trigger_mode"),
                  let mode = TriggerMode(rawValue: raw) else { return .doubleTouch }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nazar_trigger_mode") }
    }
}

// MARK: - Global Hotkey

/// Carbon-based global hotkey registry. Supports an arbitrary number of
/// hotkeys, each addressed by a string slot ID (e.g. "main", a profile UUID).
/// One global event handler dispatches to the correct callback based on the
/// Carbon EventHotKeyID we encoded with the slot.
class HotkeyManager {
    static let shared = HotkeyManager()

    struct StoredHotkey: Codable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    /// Slot reserved for the "Run Cleanup (full)" main shortcut. Profiles use
    /// their UUID string as the slot.
    static let mainSlot = "main"

    /// Back-compat: callers can still set this to register the main slot's
    /// callback before registering a key for it.
    var onTrigger: (() -> Void)? {
        didSet { triggers[Self.mainSlot] = onTrigger }
    }

    private var eventHandler: EventHandlerRef?
    private var refs: [String: EventHotKeyRef] = [:]   // slot → Carbon ref
    private var triggers: [String: () -> Void] = [:]   // slot → callback
    private var idForSlot: [String: UInt32] = [:]      // slot → hotkey ID
    private var slotForId: [UInt32: String] = [:]      // hotkey ID → slot
    private var nextId: UInt32 = 1

    private let mainDefaultsKey = "nazar_hotkey"

    private init() { installGlobalHandlerIfNeeded() }

    private func installGlobalHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            let size = MemoryLayout<EventHotKeyID>.size
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil, size, nil, &hkID)
            if let slot = HotkeyManager.shared.slotForId[hkID.id] {
                HotkeyManager.shared.triggers[slot]?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
    }

    /// Register or replace a hotkey under `slot`. The optional trigger is
    /// stored alongside; if nil, an existing trigger for that slot is kept.
    func register(slot: String, keyCode: UInt32, modifiers: UInt32, trigger: (() -> Void)? = nil) {
        unregister(slot: slot)

        let id: UInt32
        if let existing = idForSlot[slot] { id = existing }
        else { id = nextId; nextId += 1; idForSlot[slot] = id; slotForId[id] = slot }

        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4E5A52), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Logger.shared.warn("RegisterEventHotKey(slot=\(slot)) failed: status=\(status)")
            return
        }
        refs[slot] = ref
        if let trigger = trigger { triggers[slot] = trigger }
    }

    /// Remove the Carbon registration for this slot (keeps stored trigger).
    func unregister(slot: String) {
        if let ref = refs[slot] {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: slot)
        }
    }

    func unregisterAll() {
        for slot in refs.keys { unregister(slot: slot) }
    }

    /// Snapshot of slot IDs that currently hold a live Carbon registration.
    func activeSlots() -> [String] { Array(refs.keys) }

    // MARK: - Persistence (main shortcut only — profile shortcuts live on the profile)

    func register(keyCode: UInt32, modifiers: UInt32) {
        register(slot: Self.mainSlot, keyCode: keyCode, modifiers: modifiers)
    }

    func save(keyCode: UInt32, modifiers: UInt32, label: String) {
        let stored = StoredHotkey(keyCode: keyCode, modifiers: modifiers, label: label)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: mainDefaultsKey)
        }
    }

    func load() -> StoredHotkey? {
        guard let data = UserDefaults.standard.data(forKey: mainDefaultsKey),
              let stored = try? JSONDecoder().decode(StoredHotkey.self, from: data) else { return nil }
        return stored
    }

    func clear() {
        unregister(slot: Self.mainSlot)
        UserDefaults.standard.removeObject(forKey: mainDefaultsKey)
    }

    /// Migration helper: blank the legacy main-hotkey key so it stops being
    /// re-registered on launch after it's been copied into the default profile.
    func clearLegacyMainHotkey() {
        UserDefaults.standard.removeObject(forKey: mainDefaultsKey)
    }
}

// MARK: - Settings Manager

class NazarSettings {
    static let shared = NazarSettings()
    private let prefix = "nazar_step_"

    enum Step: String, CaseIterable {
        case closeApps   = "close_apps"
        case diskCleanup = "disk_cleanup"
        case updates     = "updates"
        case launchApps  = "launch_apps"

        var label: String {
            switch self {
            case .closeApps:   return "Close Apps"
            case .diskCleanup: return "Disk Cleanup"
            case .updates:     return "System Updates"
            case .launchApps:  return "Launch Startup Apps"
            }
        }
    }

    private let autoDownloadKey = "nazar_auto_download_updates"
    private let confirmKey = "nazar_confirm_before_cleanup"

    var autoDownloadUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: autoDownloadKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDownloadKey) }
    }

    /// Default true — destructive operations should ask the first few times
    /// until users explicitly disable.
    var confirmBeforeCleanup: Bool {
        get {
            if UserDefaults.standard.object(forKey: confirmKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: confirmKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: confirmKey) }
    }

    func isEnabled(_ step: Step) -> Bool {
        let key = prefix + step.rawValue
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setEnabled(_ step: Step, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: prefix + step.rawValue)
    }
}

// MARK: - Appearance Manager

class AppearanceManager {
    static let shared = AppearanceManager()

    private let iconKey = "nazar_icon_emoji"
    private let doneEmojiKey = "nazar_done_emoji"
    private let doneMessageKey = "nazar_done_message"

    var icon: String {
        get { UserDefaults.standard.string(forKey: iconKey) ?? "🧿" }
        set { UserDefaults.standard.set(newValue, forKey: iconKey) }
    }

    var doneEmoji: String {
        get { UserDefaults.standard.string(forKey: doneEmojiKey) ?? "✅" }
        set { UserDefaults.standard.set(newValue, forKey: doneEmojiKey) }
    }

    var doneMessage: String {
        get { UserDefaults.standard.string(forKey: doneMessageKey) ?? "Done" }
        set { UserDefaults.standard.set(newValue, forKey: doneMessageKey) }
    }
}

// MARK: - Protected Apps Manager

class ProtectedAppsManager {
    static let shared = ProtectedAppsManager()
    private let alwaysKey = "nazar_protected_apps_always"
    private let onceKey = "nazar_protected_apps_once"

    /// Apps that are always skipped during cleanup
    func alwaysProtected() -> [String] {
        UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []
    }

    func saveAlways(_ bundleIDs: [String]) {
        UserDefaults.standard.set(bundleIDs, forKey: alwaysKey)
    }

    func addAlways(_ bundleID: String) {
        var list = alwaysProtected()
        if !list.contains(bundleID) { list.append(bundleID) }
        saveAlways(list)
    }

    func removeAlways(_ bundleID: String) {
        var list = alwaysProtected()
        list.removeAll { $0 == bundleID }
        saveAlways(list)
    }

    /// Apps skipped only for the next cleanup (cleared after use)
    func onceProtected() -> [String] {
        UserDefaults.standard.stringArray(forKey: onceKey) ?? []
    }

    func saveOnce(_ bundleIDs: [String]) {
        UserDefaults.standard.set(bundleIDs, forKey: onceKey)
    }

    func addOnce(_ bundleID: String) {
        var list = onceProtected()
        if !list.contains(bundleID) { list.append(bundleID) }
        saveOnce(list)
    }

    func consumeOnce() -> [String] {
        let list = onceProtected()
        saveOnce([])
        return list
    }

    /// All currently protected bundle IDs
    func allProtected() -> Set<String> {
        Set(alwaysProtected() + onceProtected())
    }
}

// MARK: - Age Filter

enum AgeFilter: String, CaseIterable {
    case all       = "all"
    case days7     = "7"
    case days30    = "30"
    case days90    = "90"
    case months6   = "180"
    case year1     = "365"

    var label: String {
        switch self {
        case .all:     return "All files"
        case .days7:   return "Older than 7 days"
        case .days30:  return "Older than 30 days"
        case .days90:  return "Older than 90 days"
        case .months6: return "Older than 6 months"
        case .year1:   return "Older than 1 year"
        }
    }

    var days: Int? {
        switch self {
        case .all: return nil
        default: return Int(rawValue)
        }
    }

    static var currentDownloads: AgeFilter {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "nazar_age_downloads"),
                  let f = AgeFilter(rawValue: raw) else { return .days30 }
            return f
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nazar_age_downloads") }
    }

    /// Per-folder age filter (for custom folders)
    static func forFolder(_ id: String) -> AgeFilter {
        guard let raw = UserDefaults.standard.string(forKey: "nazar_age_\(id)"),
              let f = AgeFilter(rawValue: raw) else { return .all }
        return f
    }

    static func setForFolder(_ id: String, _ filter: AgeFilter) {
        UserDefaults.standard.set(filter.rawValue, forKey: "nazar_age_\(id)")
    }
}

// MARK: - Startup Apps Manager

class StartupAppsManager {
    static let shared = StartupAppsManager()
    private let defaultsKey = "nazar_startup_apps"

    func save(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }

    func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    func launchAll() {
        for path in load() {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    private let viewModel = NazarViewModel()
    private var isRunning = false
    private var lastClickTime: Date = .distantPast
    private var longPressTimer: Timer?
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Logger.shared.installCrashHandlers()
        Logger.shared.info("App launched — \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        // Boot the Sparkle updater early so its background poll timer arms.
        _ = UpdaterManager.shared

        // Register URL scheme handler — enables nazar://cleanup, nazar://dashboard for
        // automation (Shortcuts, scripts, testing).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Request notification permission
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.shared.error("Notification permission error: \(error.localizedDescription)")
            } else {
                Logger.shared.info("Notification permission granted=\(granted)")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = AppearanceManager.shared.icon
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp, .leftMouseDown])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 580)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MainView())

        // Ensure default profile exists (migrates legacy main-hotkey / step
        // toggles on first run with this build).
        _ = ProfileManager.shared.defaultProfile()
        registerAllProfileHotkeys()

        // First launch onboarding
        if !UserDefaults.standard.bool(forKey: "nazar_onboarding_done") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showOnboarding()
            }
        }
    }

    // MARK: - Onboarding

    func showOnboarding() {
        let steps: [OnboardingView.Step] = [
            .init(
                title: "Welcome to Nazar 🧿",
                body: """
                Nazar lives in your menu bar and keeps your Mac clean with a single gesture.

                It closes apps, cleans caches, empties trash, checks for updates, and relaunches your favorite apps — all in one go.
                """
            ),
            .init(
                title: "How to Trigger",
                body: """
                By default, double-tap the 🧿 icon to start cleanup.

                You can change this later:
                • Double Touch (trackpad tap) — default
                • Double Click (press down)
                • ⌥ Option + Click
                • Long Press (1 second)

                Right-click the icon for the menu.
                """
            ),
            .init(
                title: "⚠️ Important Warnings",
                body: """
                Please read carefully:

                • Nazar will CLOSE all running apps before cleaning. Save your work first.

                • You can PROTECT specific apps from being closed (always or one-time).

                • Downloads are filtered by age (default: 30+ days). You can change this.

                • You'll be asked to grant Finder access — needed to empty the Trash.

                • Nazar needs Full Disk Access for system caches: System Settings → Privacy & Security → Full Disk Access.
                """
            ),
            .init(
                title: "Protected Apps",
                body: """
                Don't want certain apps closed during cleanup?

                Right-click → Settings → Protected Apps lets you:

                • Always protect — app is never closed (e.g. your music player)
                • One-time protect — skip only on the next cleanup
                • Protect All Once — keep everything open just this time

                Protected apps stay running while everything else is cleaned.
                """
            ),
            .init(
                title: "Dashboard & Age Filters",
                body: """
                Right-click → Dashboard opens a detailed view where you can:

                • See all running apps and close them individually
                • View disk usage and select what to clean
                • Add your own custom folders to the cleanup list

                Age Filters (⋯ button next to Downloads & custom folders):
                • All files, 7 days, 30 days, 90 days, 6 months, 1 year
                • Downloads default: 30+ days old
                • Each folder can have its own filter

                Only checked items are cleaned — you're always in control.
                """
            ),
            .init(
                title: "Profiles & Shortcuts",
                body: """
                Build cleanup recipes that run with a single keystroke.

                Right-click → Settings → Profiles & Shortcuts:
                • Define profiles like "Light Clean" or "Just Updates"
                • Each profile picks which steps to run
                • Assign an optional global hotkey to each profile

                The built-in "Full Cleanup" profile is what your main shortcut triggers.
                """
            ),
            .init(
                title: "You're set",
                body: """
                A few extras worth knowing:

                • Settings → Appearance — change the menu bar emoji and done message
                • Settings → Startup Apps — apps that relaunch after cleanup
                • Help → Send Feedback — bug reports include logs automatically
                • Help → Check for Updates — Sparkle handles auto-updates

                Have fun. 🧿
                """
            ),
        ]

        onboarding.show(steps: steps) { [weak self] in
            UserDefaults.standard.set(true, forKey: "nazar_onboarding_done")
            self?.requestPermissions()
        }
    }

    func requestPermissions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Finder\" to get name of home"]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                Logger.shared.warn("Finder/AppleEvents permission probe failed: status=\(task.terminationStatus)")
                PermissionsHelper.promptIfNeeded(
                    pane: .appleEvents,
                    message: "Nazar uses Finder to empty the Trash during cleanup. Without this permission, Trash will be cleared via a slower fallback. Grant access under Privacy & Security → Automation."
                )
            } else {
                Logger.shared.info("AppleEvents permission probe succeeded")
            }
        } catch {
            Logger.shared.error("Failed to run permission probe: \(error.localizedDescription)")
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        // Right-click → menu
        if event.type == .rightMouseUp {
            showMenu()
            return
        }

        // Left mouse down → start long press timer
        if event.type == .leftMouseDown {
            longPressTimer?.invalidate()
            if TriggerMode.current == .longPress {
                longPressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    self?.runCleanup()
                }
            }
            return
        }

        // Left mouse up
        longPressTimer?.invalidate()
        longPressTimer = nil

        switch TriggerMode.current {
        case .doubleTouch:
            // Trackpad tap = clickCount 1 with low pressure; detect double-tap via timing
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.35 {
                runCleanup()
                lastClickTime = .distantPast
            } else {
                lastClickTime = now
            }
        case .doubleClick:
            // Full press double-click
            if event.clickCount >= 2 {
                runCleanup()
            }
        case .optionClick:
            if event.modifierFlags.contains(.option) {
                runCleanup()
            }
        case .longPress:
            break // handled in mouseDown
        }
    }

    // MARK: - Right-click menu

    func showMenu() {
        let menu = NSMenu()

        // 1. Actions
        menu.addItem(menuItem(L.t("menu.dashboard"), #selector(showDashboard)))
        menu.addItem(menuItem(L.t("menu.runCleanup"), #selector(runCleanupFromMenu), enabled: !isRunning))
        menu.addItem(profilesSubmenuItem())

        menu.addItem(.separator())

        // 2. Configuration
        menu.addItem(settingsSubmenuItem())
        menu.addItem(helpSubmenuItem())

        menu.addItem(.separator())

        // 3. Quit
        menu.addItem(menuItem(L.t("menu.quit"), #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    // MARK: - Menu builders

    private func menuItem(_ title: String, _ action: Selector?, keyEquivalent: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func profilesSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let profiles = ProfileManager.shared.load()
        if profiles.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for profile in profiles {
                let suffix = profile.hotkey.map { "  · \($0.label)" } ?? ""
                let item = NSMenuItem(title: profile.name + suffix, action: #selector(runProfileFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                item.isEnabled = !isRunning
                sub.addItem(item)
            }
        }
        sub.addItem(.separator())
        sub.addItem(menuItem("Manage…", #selector(manageProfiles)))
        parent.submenu = sub
        return parent
    }

    private func settingsSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L.t("menu.settings"), action: nil, keyEquivalent: "")
        let sub = NSMenu()

        // Unified entry point for all shortcuts + step configurations.
        sub.addItem(menuItem("Profiles & Shortcuts…", #selector(manageProfiles)))

        sub.addItem(.separator())

        let savedApps = StartupAppsManager.shared.load()
        let startupTitle = savedApps.isEmpty ? "Startup Apps…" : "Startup Apps · \(savedApps.count)"
        sub.addItem(menuItem(startupTitle, #selector(configureStartupApps)))

        let protectedAlways = ProtectedAppsManager.shared.alwaysProtected()
        let protectedTitle = protectedAlways.isEmpty ? "Protected Apps…" : "Protected Apps · \(protectedAlways.count)"
        sub.addItem(menuItem(protectedTitle, #selector(configureProtectedApps)))

        sub.addItem(menuItem("Appearance…", #selector(customizeAppearance)))

        sub.addItem(.separator())

        let trigger = NSMenuItem(title: L.t("menu.triggerMode"), action: nil, keyEquivalent: "")
        let triggerSub = NSMenu()
        for mode in TriggerMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(setTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = TriggerMode.current == mode ? .on : .off
            triggerSub.addItem(item)
        }
        trigger.submenu = triggerSub
        sub.addItem(trigger)

        sub.addItem(.separator())

        let confirm = NSMenuItem(title: L.t("menu.confirmCleanup"), action: #selector(toggleConfirmCleanup), keyEquivalent: "")
        confirm.target = self
        confirm.state = NazarSettings.shared.confirmBeforeCleanup ? .on : .off
        sub.addItem(confirm)

        let auto = NSMenuItem(title: L.t("menu.autoDownload"), action: #selector(toggleAutoDownload), keyEquivalent: "")
        auto.target = self
        auto.state = NazarSettings.shared.autoDownloadUpdates ? .on : .off
        sub.addItem(auto)

        parent.submenu = sub
        return parent
    }

    private func helpSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L.t("menu.help"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(menuItem(L.t("menu.quickRef"), #selector(showHelp)))
        sub.addItem(menuItem(L.t("menu.replayTutorial"), #selector(replayTutorial)))
        sub.addItem(.separator())
        sub.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        sub.addItem(menuItem(L.t("menu.revealLog"), #selector(revealLog)))
        sub.addItem(menuItem(L.t("menu.checkPerms"), #selector(checkPermissions)))
        sub.addItem(.separator())
        sub.addItem(menuItem(L.t("menu.feedback"), #selector(showFeedback)))
        parent.submenu = sub
        return parent
    }

    @objc func checkForUpdates() { UpdaterManager.shared.checkForUpdates() }

    // MARK: - Actions

    @objc func showDashboard() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func runCleanupFromMenu() { runCleanup() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func runProfileFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = ProfileManager.shared.load().first(where: { $0.id.uuidString == id }) else { return }
        runCleanup(steps: profile.steps, profileName: profile.name, skipConfirm: profile.skipConfirm)
    }

    @objc func manageProfiles() {
        showProfilesList()
    }

    // MARK: - Profile management UI

    /// Top-level list dialog. Sparse layout: name on a single line with a thin
    /// meta line below; actions are minimal text buttons aligned right.
    private func showProfilesList() {
        var profiles = ProfileManager.shared.load()

        let alert = NSAlert()
        alert.messageText = "Profiles"
        alert.informativeText = ""
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Done")

        let rowH: CGFloat = 48
        let listH = max(rowH * 3, CGFloat(profiles.count) * rowH + 6)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(listH, 260)))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: max(listH, CGFloat(profiles.count) * rowH + 6)))
        for (i, profile) in profiles.enumerated() {
            let y = container.frame.height - CGFloat(i + 1) * rowH

            // Name + optional DEFAULT pill
            let name = NSTextField(labelWithString: profile.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.frame = NSRect(x: 0, y: y + 24, width: 200, height: 18)
            container.addSubview(name)

            if profile.isDefault {
                let badge = NSTextField(labelWithString: "DEFAULT")
                badge.font = .systemFont(ofSize: 9, weight: .semibold)
                badge.textColor = .tertiaryLabelColor
                badge.frame = NSRect(x: 200, y: y + 26, width: 80, height: 14)
                container.addSubview(badge)
            }

            let stepNames = profile.steps.map { $0.label }.joined(separator: " · ")
            let hotkeyStr = profile.hotkey.map { "  ⌘ \($0.label)" } ?? ""
            let meta = NSTextField(labelWithString: (stepNames.isEmpty ? "no steps" : stepNames) + hotkeyStr)
            meta.font = .systemFont(ofSize: 11)
            meta.textColor = .tertiaryLabelColor
            meta.frame = NSRect(x: 0, y: y + 6, width: 285, height: 14)
            container.addSubview(meta)

            if i > 0 {
                let div = NSBox(frame: NSRect(x: 0, y: y + rowH - 1, width: 420, height: 1))
                div.boxType = .separator
                container.addSubview(div)
            }

            let run = textButton("Run", tag: i, action: #selector(runProfileButton(_:)))
            run.frame = NSRect(x: 290, y: y + 12, width: 40, height: 24)
            container.addSubview(run)

            let edit = textButton("Edit", tag: i, action: #selector(editProfileButton(_:)))
            edit.frame = NSRect(x: 332, y: y + 12, width: 44, height: 24)
            container.addSubview(edit)

            let del = textButton("✕", tag: i, action: #selector(removeProfileButton(_:)))
            del.frame = NSRect(x: 380, y: y + 12, width: 32, height: 24)
            del.isEnabled = !profile.isDefault    // default cannot be removed
            container.addSubview(del)
        }
        scroll.documentView = container
        alert.accessoryView = scroll

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let new = showProfileEditor(existing: nil) {
                ProfileManager.shared.add(new)
                registerAllProfileHotkeys()
                profiles = ProfileManager.shared.load()
                showProfilesList()
            }
        default:
            break
        }
    }

    /// Plain-styled button with no bezel — text only, used inside the
    /// management list to keep the visual rhythm.
    private func textButton(_ title: String, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.bezelStyle = .accessoryBar
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12, weight: .regular)
        return b
    }

    @objc func editProfileButton(_ sender: NSButton) {
        let profiles = ProfileManager.shared.load()
        guard sender.tag < profiles.count else { return }
        let target = profiles[sender.tag]
        if let edited = showProfileEditor(existing: target) {
            ProfileManager.shared.update(edited)
            registerAllProfileHotkeys()
        }
        sender.window?.sheetParent?.endSheet(sender.window!, returnCode: .alertSecondButtonReturn)
        showProfilesList()
    }

    @objc func runProfileButton(_ sender: NSButton) {
        let profiles = ProfileManager.shared.load()
        guard sender.tag < profiles.count else { return }
        let target = profiles[sender.tag]
        sender.window?.sheetParent?.endSheet(sender.window!, returnCode: .alertSecondButtonReturn)
        runCleanup(steps: target.steps, profileName: target.name, skipConfirm: target.skipConfirm)
    }

    @objc func removeProfileButton(_ sender: NSButton) {
        let profiles = ProfileManager.shared.load()
        guard sender.tag < profiles.count else { return }
        let target = profiles[sender.tag]
        let confirm = NSAlert()
        confirm.messageText = "Remove “\(target.name)”?"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        if confirm.runModal() == .alertFirstButtonReturn {
            ProfileManager.shared.remove(id: target.id)
            registerAllProfileHotkeys()
        }
        sender.window?.sheetParent?.endSheet(sender.window!, returnCode: .alertSecondButtonReturn)
        showProfilesList()
    }

    /// Editor for a single profile. Returns the new/updated value or nil on cancel.
    private func showProfileEditor(existing: CleanupProfile?) -> CleanupProfile? {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "New Profile" : "Edit Profile"
        alert.informativeText = ""
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))

        // Field labels — small caps, tertiary
        let nameCap = NSTextField(labelWithString: "NAME")
        nameCap.font = .systemFont(ofSize: 9, weight: .medium)
        nameCap.textColor = .tertiaryLabelColor
        nameCap.frame = NSRect(x: 0, y: 232, width: 400, height: 12)
        container.addSubview(nameCap)

        let nameField = NSTextField(string: existing?.name ?? "")
        nameField.frame = NSRect(x: 0, y: 204, width: 400, height: 24)
        nameField.placeholderString = "e.g. Light Clean"
        nameField.font = .systemFont(ofSize: 13)
        container.addSubview(nameField)

        let stepsCap = NSTextField(labelWithString: "STEPS")
        stepsCap.font = .systemFont(ofSize: 9, weight: .medium)
        stepsCap.textColor = .tertiaryLabelColor
        stepsCap.frame = NSRect(x: 0, y: 180, width: 400, height: 12)
        container.addSubview(stepsCap)

        var stepChecks: [(NSButton, NazarSettings.Step)] = []
        let selected = Set(existing?.steps ?? [])
        for (idx, step) in NazarSettings.Step.allCases.enumerated() {
            let cb = NSButton(checkboxWithTitle: step.label, target: nil, action: nil)
            cb.state = selected.contains(step) ? .on : .off
            cb.frame = NSRect(x: 0, y: 156 - CGFloat(idx * 24), width: 400, height: 20)
            container.addSubview(cb)
            stepChecks.append((cb, step))
        }

        let hotkeyCap = NSTextField(labelWithString: "SHORTCUT")
        hotkeyCap.font = .systemFont(ofSize: 9, weight: .medium)
        hotkeyCap.textColor = .tertiaryLabelColor
        hotkeyCap.frame = NSRect(x: 0, y: 58, width: 400, height: 12)
        container.addSubview(hotkeyCap)

        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 30, width: 340, height: 26))
        recorder.autoCommitOnCapture = false
        if let existing = existing?.hotkey {
            recorder.preset(label: existing.label, keyCode: existing.keyCode, modifiers: existing.modifiers)
        }
        let clearHK = NSButton(title: "Clear", target: nil, action: nil)
        clearHK.bezelStyle = .accessoryBar
        clearHK.frame = NSRect(x: 350, y: 30, width: 50, height: 26)
        clearHK.target = recorder
        clearHK.action = #selector(ShortcutRecorderView.clearRecording)
        container.addSubview(recorder)
        container.addSubview(clearHK)

        let skipConfirm = NSButton(checkboxWithTitle: "Skip confirmation for this profile",
                                   target: nil, action: nil)
        skipConfirm.state = (existing?.skipConfirm ?? false) ? .on : .off
        skipConfirm.frame = NSRect(x: 0, y: 0, width: 400, height: 20)
        container.addSubview(skipConfirm)

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let steps = stepChecks.compactMap { $0.0.state == .on ? $0.1 : nil }

        let hotkey: HotkeyManager.StoredHotkey?
        if let rec = recorder.recorded {
            hotkey = HotkeyManager.StoredHotkey(keyCode: rec.keyCode, modifiers: rec.modifiers, label: rec.label)
        } else if recorder.wasCleared {
            hotkey = nil
        } else {
            hotkey = existing?.hotkey
        }

        return CleanupProfile(
            id: existing?.id ?? UUID(),
            name: name,
            steps: steps,
            hotkey: hotkey,
            skipConfirm: skipConfirm.state == .on
        )
    }

    // MARK: - Profile hotkey wiring

    /// Re-snapshot ProfileManager and (un)register Carbon hotkeys to match.
    /// Called at launch and after any profile CRUD.
    func registerAllProfileHotkeys() {
        let profiles = ProfileManager.shared.load()
        // First, drop any existing slot that isn't a current profile id.
        let activeSlots = Set(profiles.map { $0.id.uuidString })
        for slot in HotkeyManager.shared.activeSlots() where slot != HotkeyManager.mainSlot && !activeSlots.contains(slot) {
            HotkeyManager.shared.unregister(slot: slot)
        }
        // Then register each profile that has a hotkey.
        for profile in profiles {
            let slot = profile.id.uuidString
            if let hk = profile.hotkey {
                HotkeyManager.shared.register(slot: slot, keyCode: hk.keyCode, modifiers: hk.modifiers) { [weak self] in
                    DispatchQueue.main.async {
                        self?.runCleanup(steps: profile.steps, profileName: profile.name, skipConfirm: profile.skipConfirm)
                    }
                }
            } else {
                HotkeyManager.shared.unregister(slot: slot)
            }
        }
    }

    // Handle notification tap → open System Settings
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        if response.notification.request.identifier == "nazar_updates",
           let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        handler()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }
    @objc func clearShortcut() { HotkeyManager.shared.clear() }

    @objc func showHelp() {
        let trigger = TriggerMode.current
        let shortcut = HotkeyManager.shared.load()?.label ?? "Not set"
        let startupCount = StartupAppsManager.shared.load().count

        var steps: [String] = []
        for step in NazarSettings.Step.allCases {
            let status = NazarSettings.shared.isEnabled(step) ? "ON" : "OFF"
            steps.append("  [\(status)] \(step.label)")
        }

        let protectedCount = ProtectedAppsManager.shared.alwaysProtected().count
        let dlAge = AgeFilter.currentDownloads.label

        let helpText = """
        Nazar — Menu Bar Cleaner
        Version 1.0

        HOW TO TRIGGER
        \(trigger.label): \(trigger.hint)
        You can also use: Right-click → Run Cleanup
        Keyboard shortcut: \(shortcut)

        WHAT IT DOES (in order)
        \(steps.joined(separator: "\n"))

        After cleanup, \(startupCount) app(s) will relaunch.

        PROTECTED APPS (\(protectedCount) always protected)
        • Always — app is never closed during cleanup
        • One-Time — app is skipped only on the next run
        • Set via: Right-click → Protected Apps

        AGE FILTER
        • Downloads: \(dlAge)
        • Custom folders can each have their own filter
        • Options: All, 7 days, 30 days, 90 days, 6 months, 1 year
        • Set via: Dashboard → ⋯ button next to Downloads or any folder

        RIGHT-CLICK MENU
        • Dashboard — manual cleanup with item selection
        • Run Cleanup — trigger cleanup from menu
        • Startup Apps — apps to relaunch after cleanup
        • Protected Apps — apps that won't be closed
        • Set Shortcut — global keyboard shortcut
        • Customize — change icon & done message
        • Settings — toggle steps & trigger mode

        DASHBOARD
        • Select which caches/logs/trash to clean
        • Add your own folders with "Add Folder..."
        • ⋯ button on Downloads & custom folders to set age filter
        • Age filter controls which files get deleted by age

        TIPS
        • Grant Finder access when prompted (for Trash)
        • Add to Login Items for auto-start
        """

        let alert = NSAlert()
        alert.messageText = "Nazar Help"
        alert.informativeText = helpText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func replayTutorial() {
        showOnboarding()
    }

    @objc func showFeedback() {
        FeedbackManager.shared.show()
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        Logger.shared.info("URL event: \(urlString)")
        switch url.host {
        case "cleanup":
            runCleanup()
        case "dashboard":
            DispatchQueue.main.async { self.showDashboard() }
        case "feedback":
            DispatchQueue.main.async { self.showFeedback() }
        case "profiles":
            DispatchQueue.main.async { self.manageProfiles() }
        default:
            Logger.shared.warn("Unknown URL host: \(url.host ?? "nil")")
        }
    }

    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logURL])
    }

    @objc func checkPermissions() {
        let alert = NSAlert()
        alert.messageText = "Permissions"
        alert.informativeText = """
        Nazar uses these system permissions:

        • Automation (Apple Events) — to empty the Trash via Finder.
        • Full Disk Access — to clean caches under protected paths.
        • Notifications — to show the post-cleanup summary.

        If a step is failing silently, open the corresponding pane and confirm Nazar is enabled.
        """
        alert.addButton(withTitle: "Open Automation")
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Close")
        let r = alert.runModal()
        if r == .alertFirstButtonReturn { PermissionsHelper.openSystemSettings(pane: .appleEvents) }
        else if r == .alertSecondButtonReturn { PermissionsHelper.openSystemSettings(pane: .fullDiskAccess) }
    }

    @objc func setDownloadsAge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let filter = AgeFilter(rawValue: raw) else { return }
        AgeFilter.currentDownloads = filter
    }

    @objc func configureProtectedApps() {
        let manager = ProtectedAppsManager.shared
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let alwaysList = manager.alwaysProtected()

        let alert = NSAlert()
        alert.messageText = "Protected Apps"
        alert.informativeText = "Select apps to protect from being closed.\nUse checkboxes for Always, or the One-Time button below."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 250))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: max(250, running.count * 28 + 10)))
        var checkboxes: [(NSButton, String)] = [] // (checkbox, bundleID)

        for (i, app) in running.enumerated() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let y = containerView.frame.height - CGFloat((i + 1) * 28)

            let checkbox = NSButton(checkboxWithTitle: app.localizedName ?? bundleID, target: nil, action: nil)
            checkbox.frame = NSRect(x: 10, y: y, width: 310, height: 22)
            checkbox.state = alwaysList.contains(bundleID) ? .on : .off
            containerView.addSubview(checkbox)
            checkboxes.append((checkbox, bundleID))
        }

        if running.isEmpty {
            let label = NSTextField(labelWithString: "No running apps.")
            label.frame = NSRect(x: 10, y: 110, width: 310, height: 22)
            label.alignment = .center
            containerView.addSubview(label)
        }

        scrollView.documentView = containerView
        alert.accessoryView = scrollView

        // Add one-time protect button
        alert.addButton(withTitle: "Protect All Once")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Save — update always-protected list
            var newAlways: [String] = []
            for (checkbox, bundleID) in checkboxes {
                if checkbox.state == .on {
                    newAlways.append(bundleID)
                }
            }
            manager.saveAlways(newAlways)
        } else if response == .alertThirdButtonReturn {
            // Protect all currently running apps for one-time
            for (_, bundleID) in checkboxes {
                manager.addOnce(bundleID)
            }
            let names = running.compactMap(\.localizedName).joined(separator: ", ")
            let confirm = NSAlert()
            confirm.messageText = "One-Time Protection Set"
            confirm.informativeText = "These apps will be skipped during the next cleanup only:\n\(names)"
            confirm.addButton(withTitle: "OK")
            confirm.runModal()
        }
    }

    @objc func setTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TriggerMode(rawValue: raw) else { return }
        TriggerMode.current = mode
    }

    @objc func toggleStep(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let step = NazarSettings.Step(rawValue: rawValue) else { return }
        let current = NazarSettings.shared.isEnabled(step)
        NazarSettings.shared.setEnabled(step, !current)
    }

    @objc func toggleAutoDownload() {
        NazarSettings.shared.autoDownloadUpdates = !NazarSettings.shared.autoDownloadUpdates
    }

    @objc func toggleConfirmCleanup() {
        NazarSettings.shared.confirmBeforeCleanup = !NazarSettings.shared.confirmBeforeCleanup
    }

    // MARK: - Shortcut recording

    @objc func setShortcut() {
        let alert = NSAlert()
        alert.messageText = "Set Shortcut"
        alert.informativeText = "Click the field below and press your desired key combination."
        alert.addButton(withTitle: "Cancel")

        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        alert.accessoryView = recorder
        alert.window.makeFirstResponder(recorder)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return }

        if let recorded = recorder.recorded {
            HotkeyManager.shared.save(keyCode: recorded.keyCode, modifiers: recorded.modifiers, label: recorded.label)
            HotkeyManager.shared.register(keyCode: recorded.keyCode, modifiers: recorded.modifiers)
        }
    }

    // MARK: - Customize Appearance

    @objc func customizeAppearance() {
        let appearance = AppearanceManager.shared

        let alert = NSAlert()
        alert.messageText = "Customize"
        alert.informativeText = "Edit the menu bar icon, completion emoji, and message."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 110))

        let iconLabel = NSTextField(labelWithString: "Icon Emoji:")
        iconLabel.frame = NSRect(x: 0, y: 80, width: 120, height: 22)
        let iconField = NSTextField(string: appearance.icon)
        iconField.frame = NSRect(x: 125, y: 80, width: 170, height: 22)
        iconField.placeholderString = "🧿"

        let doneEmojiLabel = NSTextField(labelWithString: "Done Emoji:")
        doneEmojiLabel.frame = NSRect(x: 0, y: 48, width: 120, height: 22)
        let doneEmojiField = NSTextField(string: appearance.doneEmoji)
        doneEmojiField.frame = NSRect(x: 125, y: 48, width: 170, height: 22)
        doneEmojiField.placeholderString = "✅"

        let doneMsgLabel = NSTextField(labelWithString: "Done Message:")
        doneMsgLabel.frame = NSRect(x: 0, y: 16, width: 120, height: 22)
        let doneMsgField = NSTextField(string: appearance.doneMessage)
        doneMsgField.frame = NSRect(x: 125, y: 16, width: 170, height: 22)
        doneMsgField.placeholderString = "Done"

        container.addSubview(iconLabel)
        container.addSubview(iconField)
        container.addSubview(doneEmojiLabel)
        container.addSubview(doneEmojiField)
        container.addSubview(doneMsgLabel)
        container.addSubview(doneMsgField)

        alert.accessoryView = container

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newIcon = iconField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newIcon.isEmpty { appearance.icon = newIcon }
        let newDoneEmoji = doneEmojiField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newDoneEmoji.isEmpty { appearance.doneEmoji = newDoneEmoji }
        let newDoneMsg = doneMsgField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newDoneMsg.isEmpty { appearance.doneMessage = newDoneMsg }

        statusItem.button?.title = appearance.icon
    }

    // MARK: - System Updates

    func checkAndInstallUpdates(progress: @escaping (String) -> Void) {
        progress("Checking for updates...")

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        task.arguments = ["-l"]
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()

        // Timeout: kill after 15 seconds to avoid hanging
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { if task.isRunning { task.terminate() } }
        timer.resume()

        task.waitUntilExit()
        timer.cancel()

        // If killed by timeout or exit code non-zero, skip
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            progress("Skipped (timed out)")
            return
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if output.contains("No new software available") || !output.contains("*") {
            progress("Up to date")
            return
        }

        let count = output.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("*") }.count

        let updateCount = max(count, 1)
        progress("\(updateCount) update(s) found")

        // Fire-and-forget download if enabled
        if NazarSettings.shared.autoDownloadUpdates {
            let dlTask = Process()
            dlTask.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            dlTask.arguments = ["-d", "-a", "--agree-to-license"]
            try? dlTask.run()
            // Don't wait — let it download in background
            progress("\(updateCount) update(s) — downloading in background")
        }

        let content = UNMutableNotificationContent()
        content.title = "🧿 Nazar — \(count) Update\(count == 1 ? "" : "s") Available"
        content.body = NazarSettings.shared.autoDownloadUpdates
            ? "Downloading in background. Open Software Update to install."
            : "Open Dashboard to see details."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "nazar_updates", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Startup Apps

    @objc func configureStartupApps() {
        let panel = NSOpenPanel()
        panel.title = "Select Apps to Launch After Cleanup"
        panel.message = "Hold ⌘ to select multiple apps."
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let response = panel.runModal()
        guard response == .OK else { return }

        let paths = panel.urls.map(\.path)
        StartupAppsManager.shared.save(paths)

        let names = panel.urls.map { $0.deletingPathExtension().lastPathComponent }
        let alert = NSAlert()
        alert.messageText = "Startup Apps Saved"
        alert.informativeText = names.joined(separator: ", ")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Clear List")
        let result = alert.runModal()
        if result == .alertSecondButtonReturn {
            StartupAppsManager.shared.save([])
        }
    }

    // MARK: - Cleanup

    /// "Run Cleanup" — uses whatever's bound to the default profile.
    func runCleanup() {
        let d = ProfileManager.shared.defaultProfile()
        runCleanup(steps: d.steps, profileName: nil, skipConfirm: d.skipConfirm)
    }

    /// Profile-aware variant. `profileName` only affects the log line and the
    /// confirmation dialog header.
    func runCleanup(steps: [NazarSettings.Step]?, profileName: String?, skipConfirm: Bool) {
        guard !isRunning else { return }

        let settings = NazarSettings.shared
        let look = AppearanceManager.shared
        let button = statusItem.button
        let icon = look.icon

        let enabledSteps: [NazarSettings.Step]
        if let steps = steps {
            enabledSteps = steps
        } else {
            enabledSteps = NazarSettings.Step.allCases.filter { settings.isEnabled($0) }
        }

        // Confirmation gate — gives users a moment to abort before destructive
        // work. Profile-triggered runs with skipConfirm=true bypass this.
        let shouldConfirm = settings.confirmBeforeCleanup && !skipConfirm && !enabledSteps.isEmpty
        if shouldConfirm {
            let stepList = enabledSteps.map { "  • \($0.label)" }.joined(separator: "\n")
            let alert = NSAlert()
            alert.messageText = L.t("alert.runCleanup.title")
            let header = profileName.map { "Profile: \($0)\n\n" } ?? ""
            alert.informativeText = "\(header)Nazar will perform these steps:\n\n\(stepList)\n\nDeleted files cannot be recovered. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: L.t("alert.runCleanup.button.run"))
            alert.addButton(withTitle: L.t("alert.runCleanup.button.cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L.t("alert.runCleanup.suppress")
            let r = alert.runModal()
            if alert.suppressionButton?.state == .on {
                settings.confirmBeforeCleanup = false
            }
            if r != .alertFirstButtonReturn { return }
        }

        isRunning = true

        guard !enabledSteps.isEmpty else {
            DispatchQueue.main.async {
                button?.title = "\(icon) \(L.t("alert.noStepsSelected"))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    button?.title = icon
                    self.isRunning = false
                }
            }
            return
        }

        let originLabel = profileName.map { "[profile=\($0)] " } ?? ""
        Logger.shared.info("\(originLabel)Cleanup started — steps: \(enabledSteps.map { $0.label }.joined(separator: ", "))")

        let stepWeight = 100.0 / Double(enabledSteps.count)

        // Status holder kept off the main thread; UI reads it via timer below.
        let statusBox = StatusBox()

        // Heartbeat timer: updates the button title at ~10 Hz from main thread.
        // The cleanup pipeline only writes to statusBox (cheap, atomic) — never
        // touches the button directly, so no jitter from main-thread contention.
        let heartbeat = Timer(timeInterval: 0.1, repeats: true) { _ in
            let snap = statusBox.snapshot()
            let pct = min(Int(snap.percent), 100)
            let label = snap.label.isEmpty ? "" : " · \(snap.label)"
            button?.title = "\(icon) \(pct)%\(label)"
        }
        RunLoop.main.add(heartbeat, forMode: .common)

        func setPct(_ stepIndex: Int, _ innerPct: Double, _ label: String) {
            let total = Double(stepIndex) * stepWeight + innerPct * stepWeight / 100.0
            statusBox.update(percent: total, label: label)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Defer invalidate so the timer is always released — even if `self`
            // is gone, the dispatch panics, or we early-return.
            defer { DispatchQueue.main.async { heartbeat.invalidate() } }

            guard let self = self else { return }

            struct StepResult {
                let name: String; let emoji: String; let success: Bool; let detail: String
            }
            var results: [StepResult] = []

            for (stepIndex, step) in enabledSteps.enumerated() {
                switch step {
                case .closeApps:
                    setPct(stepIndex, 0, L.t("status.closingApps"))
                    let outcome = self.viewModel.closeAllAppsAndWait(timeout: 2.0)
                    setPct(stepIndex, 100, L.t("status.closingApps"))

                    var detail = "\(outcome.closed.count) app(s) closed"
                    if !outcome.protected.isEmpty {
                        let names = outcome.protected.map(\.name).joined(separator: ", ")
                        detail += "\n     \(outcome.protected.count) protected: \(names)"
                    }
                    if !outcome.newlyLaunched.isEmpty {
                        let names = outcome.newlyLaunched.map(\.name).joined(separator: ", ")
                        detail += "\n     \(outcome.newlyLaunched.count) launched mid-cleanup and also closed: \(names)"
                        Logger.shared.info("Close Apps — newly launched during wait: \(names)")
                    }
                    if outcome.stillRunning.isEmpty {
                        results.append(StepResult(name: "Close Apps", emoji: "✅", success: true, detail: detail))
                    } else {
                        let failNames = outcome.stillRunning.map(\.name).joined(separator: ", ")
                        detail += "\n     \(outcome.stillRunning.count) refused to close: \(failNames)"
                        results.append(StepResult(name: "Close Apps", emoji: "⚠️", success: false, detail: detail))
                        Logger.shared.warn("Close Apps — refused: \(failNames)")
                    }

                case .diskCleanup:
                    setPct(stepIndex, 0, L.t("status.disk"))
                    let freed = self.viewModel.runPipelineCleanup { pct, label in
                        setPct(stepIndex, Double(pct), label)
                    }
                    let freedStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                    results.append(StepResult(name: "Disk Cleanup", emoji: "✅", success: true, detail: "\(freedStr) freed"))

                case .updates:
                    setPct(stepIndex, 0, L.t("status.updates"))
                    let updateProgress = ProgressHeartbeat(maxPct: 90) { pct in
                        setPct(stepIndex, pct, L.t("status.updates"))
                    }
                    updateProgress.start()
                    var updateResult = ""
                    self.checkAndInstallUpdates { status in updateResult = status }
                    updateProgress.stop()
                    setPct(stepIndex, 100, L.t("status.updates"))

                    if updateResult.contains("timed out") || updateResult.contains("Skipped") {
                        results.append(StepResult(name: "System Updates", emoji: "⚠️", success: false, detail: "Check timed out"))
                        Logger.shared.warn("Updates check timed out")
                    } else if updateResult.contains("downloading") {
                        results.append(StepResult(name: "System Updates", emoji: "📦", success: true, detail: updateResult))
                    } else if updateResult.contains("update") {
                        results.append(StepResult(name: "System Updates", emoji: "📦", success: true, detail: updateResult))
                    } else {
                        results.append(StepResult(name: "System Updates", emoji: "✅", success: true, detail: "Up to date"))
                    }

                case .launchApps:
                    setPct(stepIndex, 0, L.t("status.launch"))
                    let apps = StartupAppsManager.shared.load()
                    if !apps.isEmpty {
                        DispatchQueue.main.sync { StartupAppsManager.shared.launchAll() }
                        Thread.sleep(forTimeInterval: 1.5)
                        setPct(stepIndex, 100, L.t("status.launch"))
                        let names = apps.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                        results.append(StepResult(name: "Launch Apps", emoji: "✅", success: true, detail: names.joined(separator: ", ")))
                    } else {
                        setPct(stepIndex, 100, L.t("status.launch"))
                        results.append(StepResult(name: "Launch Apps", emoji: "✅", success: true, detail: "No apps configured"))
                    }
                }
            }

            let allSuccess = results.allSatisfy { $0.success }
            let title = allSuccess ? L.t("alert.cleanupComplete") : L.t("alert.cleanupWarnings")
            var body = ""
            for r in results { body += "\(r.emoji)  \(r.name)\n     \(r.detail)\n\n" }

            Logger.shared.info("Cleanup finished — \(allSuccess ? "success" : "warnings")")

            DispatchQueue.main.async {
                heartbeat.invalidate()
                button?.title = "\(icon) \(look.doneEmoji) \(look.doneMessage)"

                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body.trimmingCharacters(in: .whitespacesAndNewlines)
                alert.alertStyle = allSuccess ? .informational : .warning
                alert.addButton(withTitle: "OK")
                if !allSuccess { alert.addButton(withTitle: "Send Feedback") }
                let response = alert.runModal()
                if !allSuccess && response == .alertSecondButtonReturn {
                    FeedbackManager.shared.show(prefill: "Cleanup finished with warnings:\n\(body)")
                }

                button?.title = icon
                self.isRunning = false
            }
        }
    }
}

// MARK: - Shortcut Recorder View

class ShortcutRecorderView: NSView {
    struct RecordedKey {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    var recorded: RecordedKey?
    /// True if the user clicked Clear — interpreted as "remove existing hotkey".
    private(set) var wasCleared = false
    /// In the legacy main-shortcut sheet, the recorder dismisses on capture.
    /// In the profile editor it stays embedded so the user can keep editing.
    var autoCommitOnCapture: Bool = true
    private let label = NSTextField(labelWithString: "Press a key combination...")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.frame = bounds
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    /// Pre-fill with an existing hotkey so users see what's currently bound.
    func preset(label: String, keyCode: UInt32, modifiers: UInt32) {
        self.label.stringValue = label
        self.label.textColor = .labelColor
        self.recorded = RecordedKey(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    @objc func clearRecording() {
        recorded = nil
        wasCleared = true
        label.stringValue = "Press a key combination…"
        label.textColor = .secondaryLabelColor
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard !flags.isEmpty else {
            label.stringValue = "⚠ A modifier key is required (⌘⌥⌃⇧)"
            return
        }

        var parts: [String] = []
        var carbonMods: UInt32 = 0

        if flags.contains(.control) { parts.append("⌃"); carbonMods |= UInt32(controlKey) }
        if flags.contains(.option) { parts.append("⌥"); carbonMods |= UInt32(optionKey) }
        if flags.contains(.shift) { parts.append("⇧"); carbonMods |= UInt32(shiftKey) }
        if flags.contains(.command) { parts.append("⌘"); carbonMods |= UInt32(cmdKey) }

        let keyName = keyCodeToString(event.keyCode)
        parts.append(keyName)

        let combo = parts.joined()
        label.stringValue = combo
        label.textColor = .labelColor

        recorded = RecordedKey(keyCode: UInt32(event.keyCode), modifiers: carbonMods, label: combo)
        wasCleared = false

        if autoCommitOnCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let w = self.window, let parent = w.sheetParent else { return }
                parent.endSheet(w, returnCode: .alertSecondButtonReturn)
            }
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 41: ";",
            43: ",", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            51: "⌫", 53: "Esc", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 105: "F13", 109: "F10",
            111: "F12", 113: "F14", 115: "Home", 116: "PgUp", 117: "⌦",
            118: "F4", 119: "End", 120: "F2", 121: "PgDn", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            36: "↩", 48: "⇥", 76: "⌅",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

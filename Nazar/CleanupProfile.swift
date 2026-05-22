import Foundation

/// A named subset of cleanup steps with an optional global hotkey. Lets users
/// build "Light Clean", "Empty Trash Only", "Just Updates" style flows without
/// touching the main settings each time.
struct CleanupProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Stored as raw strings so it survives Step enum reorderings.
    var stepsRaw: [String]
    var hotkey: HotkeyManager.StoredHotkey?
    /// If true, skip the "Confirm Before Cleanup" dialog for this profile.
    /// Useful for one-shot profiles bound to a hotkey.
    var skipConfirm: Bool = false
    /// Exactly one profile is the default — represents the "main" cleanup.
    /// Cannot be deleted, but its name / steps / hotkey are user-editable.
    var isDefault: Bool = false

    var steps: [NazarSettings.Step] {
        get { stepsRaw.compactMap { NazarSettings.Step(rawValue: $0) } }
        set { stepsRaw = newValue.map(\.rawValue) }
    }

    init(id: UUID = UUID(), name: String, steps: [NazarSettings.Step], hotkey: HotkeyManager.StoredHotkey? = nil, skipConfirm: Bool = false, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.stepsRaw = steps.map(\.rawValue)
        self.hotkey = hotkey
        self.skipConfirm = skipConfirm
        self.isDefault = isDefault
    }
}

/// CRUD + persistence for the user's profile list. Provides a couple of
/// sensible defaults the first time it's loaded so the feature is discoverable.
final class ProfileManager {
    static let shared = ProfileManager()

    private let key = "nazar_profiles"
    private let seededKey = "nazar_profiles_seeded"

    func load() -> [CleanupProfile] {
        if !UserDefaults.standard.bool(forKey: seededKey) {
            let defaults = defaultProfiles()
            save(defaults)
            UserDefaults.standard.set(true, forKey: seededKey)
            return defaults
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([CleanupProfile].self, from: data) else { return [] }
        return profiles
    }

    func save(_ profiles: [CleanupProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ profile: CleanupProfile) {
        var list = load()
        list.append(profile)
        save(list)
    }

    @discardableResult
    func update(_ profile: CleanupProfile) -> Bool {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.id == profile.id }) else { return false }
        list[idx] = profile
        save(list)
        return true
    }

    /// Removes a profile unless it's the default — the default is the entry
    /// point for the menu's "Run Cleanup" item and must always exist.
    @discardableResult
    func remove(id: UUID) -> Bool {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        if list[idx].isDefault { return false }
        list.remove(at: idx)
        save(list)
        return true
    }

    /// Returns the default profile, creating one if missing. Migrates from
    /// legacy `nazar_hotkey` + `nazar_step_*` keys on first run so existing
    /// users keep their bindings.
    func defaultProfile() -> CleanupProfile {
        var list = load()
        if let d = list.first(where: { $0.isDefault }) { return d }

        // Migrate from pre-unification state.
        let steps = NazarSettings.Step.allCases.filter { NazarSettings.shared.isEnabled($0) }
        let legacyHotkey = HotkeyManager.shared.load()

        let defaultProfile = CleanupProfile(
            name: "Full Cleanup",
            steps: steps,
            hotkey: legacyHotkey,
            skipConfirm: false,
            isDefault: true
        )
        list.insert(defaultProfile, at: 0)
        save(list)

        // Move legacy main-hotkey persistence into the profile and clear it
        // so we don't get double registration on next launch.
        if legacyHotkey != nil { HotkeyManager.shared.clearLegacyMainHotkey() }

        return defaultProfile
    }

    private func defaultProfiles() -> [CleanupProfile] {
        [
            CleanupProfile(name: "Light Clean", steps: [.diskCleanup]),
            CleanupProfile(name: "Empty Trash Only", steps: [.diskCleanup]),
            CleanupProfile(name: "Just Updates", steps: [.updates]),
        ]
    }
}

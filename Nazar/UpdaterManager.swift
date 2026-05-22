import Foundation
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController`. The standard controller
/// already handles the menu item state, the "Check for Updates…" dialog, and
/// the install flow — we just need to own one instance for the app's lifetime
/// so the auto-check timer keeps firing.
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        Logger.shared.info("Updater armed — feed: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?")")
    }

    /// Manual "Check for Updates…" — surfaces the standard Sparkle UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether automatic background checks are enabled (toggled by user via
    /// Sparkle's prefs UI). We expose this so our menu reflects the state.
    var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

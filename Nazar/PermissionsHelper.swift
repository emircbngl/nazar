import AppKit
import Foundation

/// Centralizes prompts and deep-links for the macOS privacy panes Nazar relies
/// on. We can't programmatically check Apple Events status (no public API), so
/// the call sites detect failure (osascript non-zero exit) and ask us to
/// surface a remediation dialog.
enum PermissionsHelper {
    enum Pane: String {
        case appleEvents = "Privacy_Automation"
        case fullDiskAccess = "Privacy_AllFiles"
        case accessibility = "Privacy_Accessibility"

        var label: String {
            switch self {
            case .appleEvents: return "Automation (Apple Events)"
            case .fullDiskAccess: return "Full Disk Access"
            case .accessibility: return "Accessibility"
            }
        }
    }

    static func openSystemSettings(pane: Pane) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
        Logger.shared.info("Opened System Settings: \(pane.rawValue)")
    }

    /// Standard "you need to grant X" alert with a button that jumps straight
    /// to the right Privacy pane. Throttled so we don't nag the user on every
    /// cleanup run.
    static func promptIfNeeded(pane: Pane, message: String) {
        let key = "nazar_lastprompt_\(pane.rawValue)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        // Don't re-prompt for the same pane more than once an hour.
        if now - last < 3600 { return }
        UserDefaults.standard.set(now, forKey: key)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Nazar needs \(pane.label)"
            alert.informativeText = message
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                openSystemSettings(pane: pane)
            }
        }
    }
}

import AppKit
import Foundation

/// User-facing feedback dialog. Pre-fills system info + recent log tail so
/// reports actually contain enough context to diagnose. Three send paths:
/// Mail, Copy to Clipboard, Save to Desktop — covers users with or without
/// a mail client configured.
final class FeedbackManager {
    static let shared = FeedbackManager()

    private let feedbackEmail = "feedback@nazar.app"

    func show(prefill: String = "") {
        let alert = NSAlert()
        alert.messageText = "Send Feedback"
        alert.informativeText = "Describe what happened or what you'd like changed. System info and recent logs will be attached automatically."
        alert.addButton(withTitle: "Send via Mail")
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = prefill
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        alert.accessoryView = scroll

        let response = alert.runModal()
        let userText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = composeBody(userText: userText)

        switch response {
        case .alertFirstButtonReturn:
            sendViaMail(body: body)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            notify("Copied to clipboard — paste into an email to \(feedbackEmail).")
        default:
            break
        }
    }

    // MARK: - Body composition

    private func composeBody(userText: String) -> String {
        var s = ""
        s += userText.isEmpty ? "(no description provided)\n" : userText + "\n"
        s += "\n— — — — — — — — — — — — —\n"
        s += systemInfo()
        s += "\n— Recent log —\n"
        s += Logger.shared.recentText(maxBytes: 8 * 1024)
        return s
    }

    private func systemInfo() -> String {
        let pi = ProcessInfo.processInfo
        let v = pi.operatingSystemVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("Nazar \(appVersion) (\(build))")
        lines.append("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        lines.append("Hardware: \(hardwareModel()) · \(pi.physicalMemory / 1_073_741_824) GB RAM")
        lines.append("Locale: \(Locale.current.identifier)")
        lines.append("Trigger mode: \(TriggerMode.current.label)")
        let steps = NazarSettings.Step.allCases
            .map { "\($0.label)=\(NazarSettings.shared.isEnabled($0) ? "on" : "off")" }
            .joined(separator: ", ")
        lines.append("Steps: \(steps)")
        return lines.joined(separator: "\n")
    }

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    // MARK: - Send paths

    private func sendViaMail(body: String) {
        let subject = "Nazar Feedback"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else { return }
        if !NSWorkspace.shared.open(url) {
            // No mail client — fall back to clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            notify("No mail client found. Feedback copied to clipboard — send to \(feedbackEmail).")
        }
    }

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Feedback"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

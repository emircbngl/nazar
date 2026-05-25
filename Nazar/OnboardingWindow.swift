import AppKit
import SwiftUI

/// Persistent onboarding wizard. One window, content swaps between steps —
/// avoids the "close, reopen, close, reopen" alert flicker that drives users
/// to bail before the end.
struct OnboardingView: View {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    let steps: [Step]
    @State private var index = 0
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 420, height: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.primary.opacity(0.8) : Color.primary.opacity(0.12))
                    .frame(width: i == index ? 16 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if index == 0, let icon = Self.appIcon {
                    HStack {
                        Spacer()
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                        Spacer()
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                }
                Text(steps[index].title)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .center : .leading)
                Text(steps[index].body)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: index)
    }

    /// Best-effort app icon lookup. Falls back to bundle resource if the
    /// running app's icon image isn't available yet (early launch).
    private static var appIcon: NSImage? {
        if let img = NSApp.applicationIconImage, img.size.width > 0 { return img }
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Back") { if index > 0 { index -= 1 } }
                .buttonStyle(.bordered)
                .disabled(index == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])

            Spacer()

            Text("\(index + 1) / \(steps.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            Spacer()

            if index < steps.count - 1 {
                Button("Skip") { onDone() }
                    .buttonStyle(.bordered)
            }

            Button(index == steps.count - 1 ? "Get Started" : "Next") {
                if index == steps.count - 1 {
                    onDone()
                } else {
                    index += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Owns the window so it survives the launch closure and can be dismissed
/// from inside the SwiftUI view. Single instance held by AppDelegate.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onComplete: (() -> Void)?

    func show(steps: [OnboardingView.Step], onComplete: @escaping () -> Void) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        self.onComplete = onComplete

        let view = OnboardingView(steps: steps) { [weak self] in self?.finish() }
        let host = NSHostingController(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = host
        w.title = "Welcome to Nazar"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()
        window = nil
        let cb = onComplete
        onComplete = nil
        cb?()
    }

    // Window's red X = treat as Skip.
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        let cb = onComplete
        onComplete = nil
        cb?()
    }
}

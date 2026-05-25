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
        .frame(width: 480, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.primary.opacity(0.8) : Color.primary.opacity(0.12))
                    .frame(width: i == index ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(steps[index].title)
                    .font(.system(size: 18, weight: .semibold))
                    .id("title-\(index)")
                Text(steps[index].body)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .id("body-\(index)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        // Cross-fade between steps; window chrome stays put.
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: index)
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
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

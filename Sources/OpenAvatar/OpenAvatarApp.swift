import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct OpenAvatarApp: App {
#if canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif
    @StateObject private var app = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        // Menu-bar app. The icon is the recording indicator — it must always
        // reflect capture state (spec §5.1 hard requirement).
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .environmentObject(settings)
        } label: {
            Image(systemName: app.isListening ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(settings)
        }
    }
}

#if canImport(AppKit)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // Start the Sparkle updater (background checks + relaunch prompt).
        _ = UpdateManager.shared
        if !SettingsStore.shared.onboardingComplete {
            WindowManager.shared.showOnboarding()
        }
    }
}

/// Hosts auxiliary SwiftUI windows (onboarding, post-call review) — a plain
/// NSWindow bridge so they can be opened programmatically on macOS 14.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showOnboarding() {
        show(id: "onboarding", title: "Welcome",
             size: NSSize(width: 720, height: 560)) {
            OnboardingView()
                .environmentObject(AppState.shared)
                .environmentObject(SettingsStore.shared)
        }
    }

    func showPostCallReview() {
        show(id: "review", title: "Post-call review",
             size: NSSize(width: 640, height: 600)) {
            PostCallReviewView()
                .environmentObject(AppState.shared)
                .environmentObject(SettingsStore.shared)
        }
    }

    /// The per-call notes + live transcript window. With focus: false it
    /// appears behind the active app (the call) instead of stealing focus.
    func showCallWindow(focus: Bool = true) {
        show(id: "call", title: "Call notes",
             size: NSSize(width: 700, height: 620), focus: focus) {
            CallNotesWindowView()
                .environmentObject(AppState.shared)
                .environmentObject(SettingsStore.shared)
        }
    }

    func close(id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    private func show<Content: View>(id: String, title: String, size: NSSize,
                                     focus: Bool = true,
                                     @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            if focus {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                existing.orderFront(nil)
            }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: content())
        windows[id] = window
        if focus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
    }
}
#endif

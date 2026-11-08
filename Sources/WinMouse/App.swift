import AppKit
import SwiftUI

/// What the settings window shows besides the stored settings.
@MainActor
final class AppState: ObservableObject {
    @Published var needsAccessibility = false
    @Published var mice: [String] = []
    @Published var rivals: [String] = []  // other mouse apps running right now
}

/// Mouse utilities that rewrite the same device settings or tap the same wheel events; running two
/// makes them undo each other (existing-apps.md, Mac Mouse Fix #1112).
private let rivalApps: Set<String> = ["com.lujjjh.LinearMouse", "com.nuebling.mac-mouse-fix.helper", "com.caldis.Mos"]

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let state = AppState()
    private let pointer = PointerController()
    private let tap = MouseTap()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var applied: Settings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "WinMouse")
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item

        pointer.onMiceChange = { [weak self] in
            guard let self else { return }
            state.mice = pointer.mice
        }
        tap.onPermissionLost = { [weak self] in self?.apply(force: true) }
        // Posted on whichever thread wrote, so it is hopped to main; any defaults write lands here,
        // including window frames, and `apply` ignores what isn't a setting.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(force: false) }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(updateRivals), name: name, object: nil)
        }
        updateRivals()

        apply(force: true)
        if state.needsAccessibility {
            // Shows macOS's own "would like to control this computer" prompt, once per launch.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        // A menu bar app shows nothing when it starts, so the first launch opens the settings.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openSettings()
        }
    }

    @objc private func updateRivals() {
        let names = NSWorkspace.shared.runningApplications
            .filter { rivalApps.contains($0.bundleIdentifier ?? "") }
            .compactMap(\.localizedName)
        state.rivals = Set(names).sorted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        pointer.restoreAll()
    }

    private func apply(force: Bool) {
        let settings = Settings.load()
        guard force || settings != applied else { return }
        applied = settings
        pointer.apply(settings)
        let tapping = tap.apply(settings)
        state.needsAccessibility = settings.needsTap && !tapping
        statusItem?.button?.appearsDisabled = !settings.enabled
    }

    /// Retry when the user returns from System Settings, without an idle permission timer.
    func applicationDidBecomeActive(_ notification: Notification) {
        retryPermission()
    }

    private func retryPermission() {
        guard state.needsAccessibility, AXIsProcessTrusted() else { return }
        state.needsAccessibility = Settings.load().needsTap && !tap.apply(Settings.load())
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        retryPermission()
        menu.removeAllItems()
        let enabled = Settings.load().enabled

        let toggle = NSMenuItem(title: String(localized: "Windows Mouse"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        if enabled && state.needsAccessibility {
            menu.addItem(NSMenuItem(title: String(localized: "Allow Accessibility Access…"),
                                    action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: String(localized: "Quit WinMouse"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(!Settings.load().enabled, forKey: Settings.Key.enabled)
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(state: state, openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() })
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = .preferredContentSize   // the window follows the form's height
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "WinMouse Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

import AppKit

/// What the user can change, named and defaulted like the Windows settings they mirror.
/// Lives in the app's own defaults domain; nothing is ever written to the global domain.
struct Settings: Equatable, Sendable {
    var enabled = true                  // menu bar switch: off puts everything back to macOS
    var pointerEnabled = true           // off: external mice keep macOS pointer behaviour
    var pointerSpeed = 10               // Windows MouseSensitivity, 1...20
    var enhancePointerPrecision = true  // Windows "Enhance pointer precision"
    var scrollEnabled = true            // off: the wheel keeps macOS behaviour
    var scrollLines = 3                 // Windows "Lines to scroll at a time", 1...100
    var scrollChars = 3                 // Windows "Characters to scroll horizontally", 1...100
    var smoothScrolling = true          // Chrome/Edge animation; off jumps like classic Win32 apps
    var naturalDirection = false        // true follows macOS Natural scrolling, false is Windows' direction
    var sideButtons = true              // side buttons go back and forward in every app, as on Windows
    var controlZoom = true              // Control + wheel zooms, Windows' Ctrl + wheel

    /// The keys, shared with the settings window's @AppStorage.
    enum Key {
        static let enabled = "enabled", pointerEnabled = "pointerEnabled", pointerSpeed = "pointerSpeed"
        static let enhancePointerPrecision = "enhancePointerPrecision", scrollEnabled = "scrollEnabled"
        static let scrollLines = "scrollLines", scrollChars = "scrollChars", smoothScrolling = "smoothScrolling"
        static let naturalDirection = "naturalDirection", sideButtons = "sideButtons", controlZoom = "controlZoom"
        static let automaticUpdates = "automaticUpdates"
    }

    /// Whether anything needs the event tap, and so Accessibility access.
    var needsTap: Bool { enabled && (scrollEnabled || sideButtons) }

    /// Defaults registered once at launch, so the settings window and `load` agree on them.
    /// Smooth scrolling starts off under Reduce Motion, as Chrome does with Windows animations off.
    static func registerDefaults() {
        var initial = Settings()
        initial.smoothScrolling = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        UserDefaults.standard.register(defaults: [
            Key.enabled: initial.enabled,
            Key.pointerEnabled: initial.pointerEnabled,
            Key.pointerSpeed: initial.pointerSpeed,
            Key.enhancePointerPrecision: initial.enhancePointerPrecision,
            Key.scrollEnabled: initial.scrollEnabled,
            Key.scrollLines: initial.scrollLines,
            Key.scrollChars: initial.scrollChars,
            Key.smoothScrolling: initial.smoothScrolling,
            Key.naturalDirection: initial.naturalDirection,
            Key.sideButtons: initial.sideButtons,
            Key.controlZoom: initial.controlZoom,
            Key.automaticUpdates: true,
        ])
    }

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        return Settings(
            enabled: defaults.bool(forKey: Key.enabled),
            pointerEnabled: defaults.bool(forKey: Key.pointerEnabled),
            pointerSpeed: min(max(defaults.integer(forKey: Key.pointerSpeed), 1), 20),
            enhancePointerPrecision: defaults.bool(forKey: Key.enhancePointerPrecision),
            scrollEnabled: defaults.bool(forKey: Key.scrollEnabled),
            scrollLines: min(max(defaults.integer(forKey: Key.scrollLines), 1), 100),
            scrollChars: min(max(defaults.integer(forKey: Key.scrollChars), 1), 100),
            smoothScrolling: defaults.bool(forKey: Key.smoothScrolling),
            naturalDirection: defaults.bool(forKey: Key.naturalDirection),
            sideButtons: defaults.bool(forKey: Key.sideButtons),
            controlZoom: defaults.bool(forKey: Key.controlZoom))
    }
}

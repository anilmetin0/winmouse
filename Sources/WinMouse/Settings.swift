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

    /// Defaults registered once at launch, so the settings window and `load` agree on them.
    /// Smooth scrolling starts off under Reduce Motion, as Chrome does with Windows animations off.
    static func registerDefaults() {
        var initial = Settings()
        initial.smoothScrolling = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        UserDefaults.standard.register(defaults: [
            "enabled": initial.enabled,
            "pointerEnabled": initial.pointerEnabled,
            "pointerSpeed": initial.pointerSpeed,
            "enhancePointerPrecision": initial.enhancePointerPrecision,
            "scrollEnabled": initial.scrollEnabled,
            "scrollLines": initial.scrollLines,
            "scrollChars": initial.scrollChars,
            "smoothScrolling": initial.smoothScrolling,
            "naturalDirection": initial.naturalDirection,
        ])
    }

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        return Settings(
            enabled: defaults.bool(forKey: "enabled"),
            pointerEnabled: defaults.bool(forKey: "pointerEnabled"),
            pointerSpeed: min(max(defaults.integer(forKey: "pointerSpeed"), 1), 20),
            enhancePointerPrecision: defaults.bool(forKey: "enhancePointerPrecision"),
            scrollEnabled: defaults.bool(forKey: "scrollEnabled"),
            scrollLines: min(max(defaults.integer(forKey: "scrollLines"), 1), 100),
            scrollChars: min(max(defaults.integer(forKey: "scrollChars"), 1), 100),
            smoothScrolling: defaults.bool(forKey: "smoothScrolling"),
            naturalDirection: defaults.bool(forKey: "naturalDirection"))
    }
}

import CoreGraphics
import Foundation

// Side buttons and Control + wheel as on Windows (docs/research/windows-buttons.md). Windows turns
// the side buttons into Back and Forward for every window; on macOS only some apps read them, so
// the Apple apps that don't get their own Back or Forward shortcut instead.

/// The two side buttons, by CGEvent button number (windows-buttons.md §3).
enum SideButton: Sendable {
    case back, forward

    init?(_ number: Int64) {
        switch number {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

/// A key press with exactly these modifiers. Codes are positions, not characters (Carbon's kVK_*),
/// which is what macOS localizes menu shortcuts to on other keyboard layouts (windows-buttons.md §4).
struct KeyStroke: Equatable, Sendable {
    let code: CGKeyCode
    let flags: CGEventFlags
}

private let leftBracket: CGKeyCode = 0x21, rightBracket: CGKeyCode = 0x1E
private let leftArrow: CGKeyCode = 0x7B, rightArrow: CGKeyCode = 0x7C
private let minus: CGKeyCode = 0x1B, equal: CGKeyCode = 0x18

/// Apps that ignore the side buttons but go back and forward with Command-[ and Command-]
/// (windows-buttons.md §3.2, §4, §8). Every other app keeps the buttons: Chrome, Edge, Firefox,
/// VS Code and JetBrains IDEs handle them, and elsewhere Command-[ often means indent.
private let bracketApps: Set<String> = [
    "com.apple.finder", "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.systempreferences",
    "com.apple.AppStore", "com.apple.Music", "com.apple.TV", "com.apple.Preview",
]

/// Apps with their own Back and Forward shortcuts (windows-buttons.md §4, §8).
private let ownShortcuts: [String: (back: KeyStroke, forward: KeyStroke)] = [
    "com.apple.dt.Xcode": (KeyStroke(code: leftArrow, flags: [.maskControl, .maskCommand]),
                           KeyStroke(code: rightArrow, flags: [.maskControl, .maskCommand])),
]

/// What a side button does in the app with `bundleID`: the shortcut to press, or nil to leave the
/// button to the app.
func navigationKeys(_ button: SideButton, app bundleID: String?) -> KeyStroke? {
    guard let bundleID else { return nil }
    if let own = ownShortcuts[bundleID] { return button == .back ? own.back : own.forward }
    guard bracketApps.contains(bundleID) else { return nil }
    return KeyStroke(code: button == .back ? leftBracket : rightBracket, flags: .maskCommand)
}

/// Command-= or Command--, the zoom shortcuts of macOS apps, for one Control + wheel notch
/// (windows-buttons.md §2, §4).
func zoom(in zoomIn: Bool) -> KeyStroke {
    KeyStroke(code: zoomIn ? equal : minus, flags: .maskCommand)
}

/// Whether macOS's own Zoom is set to zoom the screen with Control + wheel, which then comes first
/// (windows-buttons.md §5). Read only; another app's domain is never written.
func accessibilityZoomUsesControlWheel() -> Bool {
    let access = UserDefaults(suiteName: "com.apple.universalaccess")
    guard access?.bool(forKey: "closeViewScrollWheelToggle") == true else { return false }
    // 1 << 18 is Control in NSEvent.ModifierFlags; Control is the default when the key is absent.
    let modifiers = access?.object(forKey: "closeViewScrollWheelModifiersInt") as? Int ?? 1 << 18
    return modifiers & (1 << 18) != 0
}

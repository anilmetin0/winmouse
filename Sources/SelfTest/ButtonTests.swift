import AppKit

// Side buttons and Control + wheel against docs/research/windows-buttons.md.

func buttonTests() {
    check(SideButton(3) == .back && SideButton(4) == .forward && SideButton(2) == nil && SideButton(0) == nil,
          "side buttons are CGEvent buttons 3 and 4")

    // Native apps keep the button; Finder and Safari get Command-[ and Command-].
    check(navigationKeys(.back, app: "com.google.Chrome") == nil, "Chrome handles the side buttons itself")
    check(navigationKeys(.forward, app: "org.mozilla.firefox") == nil, "Firefox handles the side buttons itself")
    let back = navigationKeys(.back, app: "com.apple.finder"), forward = navigationKeys(.forward, app: "com.apple.Safari")
    check(back == KeyStroke(code: 0x21, flags: .maskCommand), "Finder back: \(String(describing: back))")
    check(forward == KeyStroke(code: 0x1E, flags: .maskCommand), "Safari forward: \(String(describing: forward))")
    check(navigationKeys(.back, app: nil) == nil, "no front app: the button passes")
    check(navigationKeys(.back, app: "com.apple.Notes") == nil, "Notes keeps the button: Command-[ is indent there")
    check(navigationKeys(.forward, app: "com.microsoft.VSCode") == nil, "VS Code handles the side buttons itself")
    check(navigationKeys(.back, app: "com.apple.dt.Xcode") == KeyStroke(code: 0x7B, flags: [.maskControl, .maskCommand]),
          "Xcode back is Control-Command-Left, not Command-[ (Shift Left)")

    check(zoom(in: true).flags == .maskCommand && zoom(in: false).flags == .maskCommand, "zoom must carry Command only")
    check(zoom(in: true).code == 0x18 && zoom(in: false).code == 0x1B, "zoom keys are = and -")
}

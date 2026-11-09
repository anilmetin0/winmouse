"""Exercise MouseTap's real delivery into a fresh AppKit scroll view, without a HID tap."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix="winmouse-scroll-routing-"))
print(f"Scroll routing fixture: {root}", flush=True)
source = (repo / "Sources/WinMouse/MouseTap.swift").read_text()
source += '''
extension MouseTap {
    func fixtureNotch(at point: CGPoint) -> [String: Double] {
        settings.smoothScrolling = false
        front = FrontApp(NSRunningApplication.current)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: -1, wheel2: 0, wheel3: 0)!
        event.location = point
        event.flags = []
        event.setIntegerValueField(senderField, value: 1)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
        let fields: [String: Double] = [
            "sender": Double(event.getIntegerValueField(senderField)),
            "continuous": Double(event.getIntegerValueField(.scrollWheelEventIsContinuous)),
            "phase": Double(event.getIntegerValueField(.scrollWheelEventScrollPhase)),
            "momentum": Double(event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
            "notch": Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
            "taken": wheel(event) ? 1 : 0,
        ]
        return fields
    }
}
'''
(root / "MouseTap.swift").write_text(source)
fixture = '''
import AppKit

final class Document: NSView {
    override var isFlipped: Bool { true }
}

@main @MainActor final class Fixture: NSObject, NSApplicationDelegate {
    let tap = MouseTap()
    var window: NSWindow!
    var otherWindow: NSWindow!
    var scroll: NSScrollView!
    var before = 0.0
    var point = CGPoint.zero
    var result: [String: Double] = [:]

    static func main() {
        let app = NSApplication.shared
        let delegate = Fixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WinMouse scroll routing test"
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 360, height: 3000))
        scroll.hasVerticalScroller = true
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let screenHeight = NSScreen.screens[0].frame.maxY
        point = CGPoint(x: window.frame.midX, y: screenHeight - window.frame.midY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.production() }
    }

    func production() {
        before = scroll.contentView.bounds.origin.y
        result.merge(tap.fixtureNotch(at: point)) { _, value in value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.result["production"] = self.scroll.contentView.bounds.origin.y - self.before
            self.session()
        }
    }

    func session() {
        before = scroll.contentView.bounds.origin.y
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: -100, wheel2: 0, wheel3: 0)!
        event.location = point
        event.flags = []
        event.post(tap: .cgSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.result["session"] = self.scroll.contentView.bounds.origin.y - self.before
            self.inactiveWindow()
        }
    }

    func inactiveWindow() {
        otherWindow = NSWindow(contentRect: NSRect(x: 520, y: 120, width: 360, height: 260),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        otherWindow.title = "WinMouse active test window"
        otherWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.before = self.scroll.contentView.bounds.origin.y
            self.result["targetIsKey"] = self.window.isKeyWindow ? 1 : 0
            _ = self.tap.fixtureNotch(at: self.point)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish() }
        }
    }

    func finish() {
        result["inactive"] = scroll.contentView.bounds.origin.y - before
        result["postAccess"] = CGPreflightPostEventAccess() ? 1 : 0
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: "__RESULT__"))
        NSApp.terminate(nil)
    }
}
'''.replace("__RESULT__", str(root / "result.json"))
(root / "Fixture.swift").write_text(fixture)
app = root / "ScrollRouting.app"
(app / "Contents/MacOS").mkdir(parents=True)
inputs = [repo / "Sources/WinMouse" / name for name in
          ["Settings.swift", "Buttons.swift", "WheelEvents.swift", "ScrollAnimation.swift"]]
subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-disable-sandbox", "-parse-as-library",
                "-module-cache-path", str(repo / "build/ModuleCache"),
                *map(str, inputs), str(root / "MouseTap.swift"), str(root / "Fixture.swift"),
                "-o", str(app / "Contents/MacOS/ScrollRouting")], check=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "io.github.anilmetin0.winmouse-scroll-test." + uuid.uuid4().hex,
    "CFBundleExecutable": "ScrollRouting", "CFBundlePackageType": "APPL",
}))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
# LaunchServices gives this unique fixture no posting permission. Running the executable as a
# child inherits the invoking terminal's Accessibility permission, without changing TCC settings.
subprocess.run([str(app / "Contents/MacOS/ScrollRouting")], check=True, timeout=15)
result = json.loads((root / "result.json").read_text())
print(result, flush=True)
assert result["session"] > 0, "Control event must scroll the real AppKit view"
assert result["postAccess"] == 1, "Run from a terminal with Accessibility access; no TCC grants are changed"
assert result["taken"] == 1, "Fixture notch must exercise MouseTap's replacement path"
assert result["production"] == result["session"] == 100, "MouseTap must deliver the full notch to the view"
assert result["targetIsKey"] == 0 and result["inactive"] == 100, "The original location must route to the inactive window"
print("Fresh and inactive-window MouseTap scroll delivery PASS", flush=True)

import AppKit
import OSLog
import QuartzCore

/// The one event tap: Chrome/Edge-on-Windows wheel scrolling (docs/research/windows-scroll.md §8),
/// Control + wheel zoom, and side buttons that go back and forward in apps that ignore them
/// (docs/research/windows-buttons.md). It sees wheel events and other-button presses and releases
/// only; trackpads, Magic Mouse and mice whose driver already scrolls smoothly pass untouched.
///
/// Threads: `apply`, `stop` and the notification handlers run on the main thread, which owns `loop`,
/// `ended` and `onPermissionLost`. Everything else belongs to the engine thread. Main writes that
/// state only while no engine thread exists (`stop` waits for it to end) and otherwise hands values
/// over with `onEngine`.
final class MouseTap: NSObject, @unchecked Sendable {
    var onPermissionLost: (@MainActor () -> Void)?

    private var loop: CFRunLoop?          // main: the engine thread's run loop while the tap runs
    private var ended: DispatchSemaphore? // main: signalled when that thread has finished

    // Engine thread from here on.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var health: Timer?
    private var link: CADisplayLink?
    private var settings = Settings()
    private var front = FrontApp(nil)
    private var vertical = WheelAxis(), horizontal = WheelAxis()
    private var flags: CGEventFlags = []  // modifiers of the latest notch, for the frames it drives
    private var lastFrame = 0.0           // targetTimestamp of the latest frame
    private var held: [Int64: KeyStroke] = [:]  // side buttons held back, with the shortcut for their release
    private var zoomTaken = false         // macOS zoom already uses Control + wheel

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            guard loop != nil else { return }
            let app = FrontApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            onEngine { self.front = app }
        }
        _ = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [self] _ in
            replaceLink()
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [self] _ in
            replaceLink()
        }
    }

    /// Main thread. Starts, updates or stops the tap; false when it is wanted but can't run.
    @discardableResult func apply(_ settings: Settings) -> Bool {
        guard settings.needsTap && AXIsProcessTrusted() else {
            stop()
            return false
        }
        guard loop == nil else {
            let taken = accessibilityZoomUsesControlWheel()
            onEngine { self.settings = settings; self.zoomTaken = taken }
            return true
        }
        return start(settings)
    }

    func stop() {
        guard let ended else { return }
        onEngine { self.shutDown() }
        loop = nil
        ended.wait()  // so the next `start` never shares state with a thread that is still ending
        self.ended = nil
    }

    private func start(_ settings: Settings) -> Bool {
        let mask = [CGEventType.scrollWheel, .otherMouseDown, .otherMouseUp]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, engine in
                Unmanaged<MouseTap>.fromOpaque(engine!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        self.settings = settings
        front = FrontApp(NSWorkspace.shared.frontmostApplication)
        vertical = WheelAxis()  // forget what a stopped animation never posted
        horizontal = WheelAxis()
        held = [:]
        zoomTaken = accessibilityZoomUsesControlWheel()
        let started = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let thread = Thread { self.run(started, ended) }
        thread.name = "WinMouse tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        self.ended = ended
        replaceLink()
        return true
    }

    /// The engine thread: the tap and the health check on its own run loop until `shutDown`.
    private func run(_ started: DispatchSemaphore, _ ended: DispatchSemaphore) {
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        let health = Timer(timeInterval: 5, repeats: true) { _ in self.checkHealth() }
        RunLoop.current.add(health, forMode: .common)
        self.health = health
        loop = CFRunLoopGetCurrent()  // main reads it once `started` fires
        started.signal()
        CFRunLoopRun()
        ended.signal()
    }

    /// Main thread: runs `work` on the engine thread, if it is running.
    private func onEngine(_ work: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    /// Engine thread, every 5 s: re-enables a tap macOS switched off without an event (macos-hid.md
    /// §6), and removes the tap at once when Accessibility is revoked, because a tap left running
    /// without it froze all input in Mos (existing-apps.md §3.4).
    private func checkHealth() {
        guard let tap else { return }
        if !AXIsProcessTrusted() {
            shutDown()
            DispatchQueue.main.async {
                self.stop()
                self.onPermissionLost?()
            }
        } else {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            zoomTaken = accessibilityZoomUsesControlWheel()  // macOS Zoom has no change notification
        }
    }

    /// Engine thread: removes the tap and the frame driver, then ends the thread.
    private func shutDown() {
        if let tap {
            // Disabled is not enough: WindowServer keeps a valid tap, which slowed all input in Mos
            // (#970, existing-apps.md §2.4).
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        link?.invalidate()
        health?.invalidate()
        tap = nil
        source = nil
        link = nil
        health = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// Main thread: a new display link from AppKit, which the engine thread adds to its own run loop.
    /// Replaced after screen changes and wake, when the old one can be tied to a display that is gone
    /// or to a stale refresh rate (Mos #958, existing-apps.md §3.2).
    private func replaceLink() {
        guard loop != nil else { return }
        // ponytail: one screen paces every frame; per-screen links if mixed refresh rates stutter.
        let link = NSScreen.main?.displayLink(target: self, selector: #selector(frame))
        onEngine { self.use(link) }
    }

    /// Engine thread.
    private func use(_ newLink: CADisplayLink?) {
        link?.invalidate()
        link = newLink
        newLink?.add(to: .current, forMode: .common)
        newLink?.isPaused = idle(at: CACurrentMediaTime())
    }

    /// Engine thread, inside the tap: stays short, because macOS disables a tap that answers slowly.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            held = [:]  // releases may have gone by unseen
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            return wheel(event) ? nil : Unmanaged.passUnretained(event)
        case .otherMouseDown, .otherMouseUp:
            return button(event, down: type == .otherMouseDown) ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Wheel

    /// Engine thread: true when the event was taken over and must not reach the app.
    private func wheel(_ event: CGEvent) -> Bool {
        guard settings.scrollEnabled, isDeviceNotch(event) else { return false }
        let up = notches(event, .scrollWheelEventDeltaAxis1)
        let left = notches(event, .scrollWheelEventDeltaAxis2)
        // Debug level: costs nothing unless someone streams it (`log stream --level debug ...`).
        log.debug("""
            wheel lines \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) \
            raw \(event.getDoubleValueField(rawDeltaAxis1)) \
            inverted \(isInvertedFromDevice(event)) sender \(event.getIntegerValueField(senderField)) -> notches \(up), \(left)
            """)
        guard up != 0 || left != 0 else { return false }
        let inverted = isInvertedFromDevice(event)
        let reverse = !settings.naturalDirection && inverted
        let flags = event.flags

        if front.isGame {
            // Games keep macOS behaviour apart from the direction: smoothed pixel events break
            // weapon and hotbar wheels (existing-apps.md §3.3).
            if reverse { reverseDirection(event) }
            return false
        }
        if settings.controlZoom, up != 0, isControlOnly(flags), !zoomTaken, front.bundleID != nil {
            // Ctrl + wheel away from the user zooms in (windows-scroll.md §1), one step per notch.
            postKeys(zoom(in: (inverted ? -up : up) > 0))
            return true
        }
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            if reverse { reverseDirection(event) }
            return false
        }

        let lines = notchDistance(settings.scrollLines)
        var dy = up * lines, dx = left * notchDistance(settings.scrollChars)
        if flags.contains(.maskShift) && (up == 0 || left == 0) {
            // Chrome scrolls Shift + wheel sideways by the vertical distance (windows-scroll.md §5).
            // A notch macOS has already moved to x gets the lines distance as well.
            dx = (up + left) * lines
            dy = 0
        }
        if reverse {
            dx = -dx
            dy = -dy
        }
        self.flags = flags.subtracting(.maskShift)  // so no app turns our events sideways again

        let now = max(CACurrentMediaTime(), lastFrame)  // never behind what the last frame posted
        if settings.smoothScrolling, let link {
            if dy != 0 { vertical.animation.notch(at: now, distance: dy) }
            if dx != 0 { horizontal.animation.notch(at: now, distance: dx) }
            link.isPaused = false
        } else {
            if dy != 0 { vertical.animation.jump(at: now, distance: dy) }
            if dx != 0 { horizontal.animation.jump(at: now, distance: dx) }
            post(at: now)
        }
        return true
    }

    /// Engine thread, once per display frame while an animation runs.
    @objc private func frame(_ link: CADisplayLink) {
        lastFrame = link.targetTimestamp
        post(at: lastFrame)
        link.isPaused = idle(at: lastFrame)
    }

    /// Engine thread: posts how far the animations moved since the last post, in whole points.
    /// Pixel events without phases, so apps scroll by exactly that and add no momentum or bounce.
    private func post(at t: Double) {
        let dy = vertical.step(at: t), dx = horizontal.step(at: t)
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.flags = flags
        // ponytail: frames go to whatever is under the pointer now, so moving it mid-animation hands
        // the rest to the next view; post to the notch's app (existing-apps.md §6 item 9) if noticed.
        event.post(tap: .cgSessionEventTap)
    }

    private func idle(at t: Double) -> Bool {
        vertical.animation.isFinished(at: t) && horizontal.animation.isFinished(at: t)
    }

    // MARK: Buttons

    /// Engine thread: true when the event was taken over. Windows navigates on release
    /// (windows-buttons.md §1.1), so the press is held back and the shortcut goes out with the
    /// release, whatever the settings say by then, so no app sees half a click.
    private func button(_ event: CGEvent, down: Bool) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let side = SideButton(number) else { return false }
        guard down else {
            guard let keys = held.removeValue(forKey: number) else { return false }
            postKeys(keys)
            return true
        }
        held[number] = nil  // a release the tap missed must not fire later
        guard settings.sideButtons, !front.isGame,
              event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift]),
              let keys = navigationKeys(side, app: front.bundleID),
              // The shortcut goes to the active app; over another app's window the button stays a
              // button, which Windows would send to that window (windows-buttons.md §7 item 2).
              isOverFrontApp(event)
        else { return false }
        held[number] = keys
        return true
    }

    /// Engine thread: whether the window under the pointer belongs to the active app. Unknown
    /// windows count as yes, so the menu bar and desktop behave like the app itself.
    private func isOverFrontApp(_ event: CGEvent) -> Bool {
        let window = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        guard window > 0, let front = front.pid,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window)) as? [[String: Any]],
              let owner = info.first?[kCGWindowOwnerPID as String] as? pid_t
        else { return true }
        return owner == front
    }

    /// Engine thread: a key press and release with exactly `keys.flags` held, so the user's own
    /// modifiers can't turn it into another shortcut.
    private func postKeys(_ keys: KeyStroke) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keys.code, keyDown: down) else { return }
            event.flags = keys.flags
            event.post(tap: .cgSessionEventTap)
        }
    }
}

/// What the tap needs to know about the active app, read on the main thread.
private struct FrontApp {
    let bundleID: String?
    let pid: pid_t?
    let isGame: Bool  // declares itself a game in its Info.plist

    init(_ app: NSRunningApplication?) {
        bundleID = app?.bundleIdentifier
        pid = app?.processIdentifier
        let category = app?.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") } as? String
        isGame = category?.contains("games") ?? false
    }
}

private func isControlOnly(_ flags: CGEventFlags) -> Bool {
    flags.contains(.maskControl) && flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskShift])
}

private let log = Logger(subsystem: "io.github.anilmetin0.winmouse", category: "tap")

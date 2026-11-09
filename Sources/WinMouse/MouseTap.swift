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
    var onInputIdle: (@MainActor () -> Void)?
    private let updateLock = NSLock()
    private var updateIdle = true

    @MainActor var canRestartForUpdate: Bool {
        guard loop != nil else { return true }
        updateLock.lock()
        defer { updateLock.unlock() }
        return updateIdle
    }

    private func setUpdateIdle(_ idle: Bool) {
        updateLock.lock()
        let becameIdle = idle && !updateIdle
        updateIdle = idle
        updateLock.unlock()
        if becameIdle { DispatchQueue.main.async { self.onInputIdle?() } }
    }

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
    private var sequence = WheelSequence()
    private var scrollLocation = CGPoint.zero
    private var scrollPID: pid_t?
    private var groupedScroll = false
    private var held: [Int64: (keys: KeyStroke, pid: pid_t?)] = [:]
    private var zoomTaken = false         // macOS zoom already uses Control + wheel

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            guard loop != nil else { return }
            let app = FrontApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            onEngine { self.cancelScroll(); self.front = app }
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
            onEngine {
                if self.settings != settings { self.cancelScroll() }
                self.settings = settings; self.zoomTaken = taken
            }
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
        sequence = WheelSequence()
        lastFrame = 0
        held = [:]
        setUpdateIdle(true)
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
        cancelScroll()
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
            cancelScroll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            held = [:]  // releases may have gone by unseen
            setUpdateIdle(true)
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
        guard settings.scrollEnabled, isDeviceNotch(event) else {
            cancelScroll()
            return false
        }
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
            cancelScroll()
            // Games keep macOS behaviour apart from the direction: smoothed pixel events break
            // weapon and hotbar wheels (existing-apps.md §3.3).
            if reverse { reverseDirection(event) }
            return false
        }
        if settings.controlZoom, up != 0, isControlOnly(flags), !zoomTaken, front.bundleID != nil {
            cancelScroll()
            // Ctrl + wheel away from the user zooms in (windows-scroll.md §1), one step per notch.
            postKeys(zoom(in: (inverted ? -up : up) > 0))
            return true
        }
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            cancelScroll()
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
        let outputFlags = flags.subtracting(.maskShift)
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let pid = targetPID > 0 && targetPID <= Int64(Int32.max) ? pid_t(targetPID) : windowOwner(event)
        if self.flags != outputFlags || scrollPID != pid { cancelScroll() }
        if idle(at: max(CACurrentMediaTime(), lastFrame)) {
            // A delayed display callback may still owe the final delta of an older gesture.
            post(at: max(CACurrentMediaTime(), lastFrame))
            scrollLocation = event.location
            scrollPID = pid
            let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }?.bundleIdentifier
            groupedScroll = groupsWheelFrames(in: app ?? (isOverFrontApp(event) ? front.bundleID : nil))
        }
        self.flags = outputFlags  // so no app turns our events sideways again

        let now = max(CACurrentMediaTime(), lastFrame)  // never behind what the last frame posted
        if settings.smoothScrolling, let link {
            if dy != 0 { vertical.animation.notch(at: now, distance: dy) }
            if dx != 0 { horizontal.animation.notch(at: now, distance: dx) }
            link.isPaused = false
            setUpdateIdle(false)
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
        setUpdateIdle(link.isPaused && held.isEmpty)
    }

    /// Engine thread: posts how far the animations moved since the last post, in whole points.
    /// Browser frames share one phase sequence. No momentum or companion gesture events.
    private func post(at t: Double) {
        let dy = vertical.step(at: t), dx = horizontal.step(at: t)
        if let event = sequence.event(dy: dy, dx: dx, grouped: groupedScroll && settings.smoothScrolling) {
            deliver(event)
        }
        if idle(at: t), let end = sequence.end() { deliver(end) }
    }

    private func deliver(_ event: CGEvent) {
        event.flags = flags
        event.location = scrollLocation
        // New pixel events have no window annotation. Posting straight to a PID bypasses
        // WindowServer's routing and can silently drop scrolling in a fresh app/window (#3).
        // The frozen notch location keeps the tail in place while the session annotates it.
        event.post(tap: .cgSessionEventTap)
    }

    /// Don't let a setting change, another app or native trackpad input inherit a wheel tail.
    private func cancelScroll() {
        if let end = sequence.end(cancelled: true) { deliver(end) }
        vertical = WheelAxis()
        horizontal = WheelAxis()
        link?.isPaused = true
        setUpdateIdle(held.isEmpty)
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
            guard let press = held.removeValue(forKey: number) else {
                setUpdateIdle(idle(at: CACurrentMediaTime()) && held.isEmpty)
                return false
            }
            if press.pid == front.pid { postKeys(press.keys) }
            setUpdateIdle(idle(at: CACurrentMediaTime()) && held.isEmpty)
            return true
        }
        held[number] = nil  // a release the tap missed must not fire later
        guard settings.sideButtons, !front.isGame,
              event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift]),
              let keys = navigationKeys(side, app: front.bundleID),
              // The shortcut goes to the active app; over another app's window the button stays a
              // button, which Windows would send to that window (windows-buttons.md §7 item 2).
              isOverFrontApp(event)
        else {
            setUpdateIdle(idle(at: CACurrentMediaTime()) && held.isEmpty)
            return false
        }
        held[number] = (keys, front.pid)
        setUpdateIdle(false)
        return true
    }

    /// Engine thread: whether the window under the pointer belongs to the active app. Unknown
    /// windows count as yes, so the menu bar and desktop behave like the app itself.
    private func isOverFrontApp(_ event: CGEvent) -> Bool {
        guard let owner = windowOwner(event), let front = front.pid else { return true }
        return owner == front
    }

    private func windowOwner(_ event: CGEvent) -> pid_t? {
        let window = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        guard window > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window)) as? [[String: Any]],
              let owner = info.first?[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        return owner
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

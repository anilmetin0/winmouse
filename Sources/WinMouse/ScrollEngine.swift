import AppKit
import OSLog
import QuartzCore

/// Chrome/Edge-on-Windows scrolling for an external mouse wheel (docs/research/windows-scroll.md
/// §8): each notch moves a fixed distance with a short ease-in-out, with no acceleration and no
/// momentum. Trackpads, Magic Mouse and mice whose driver already scrolls smoothly pass untouched.
///
/// Threads: `apply`, `stop` and the notification handlers run on the main thread, which owns `loop`,
/// `ended` and `onPermissionLost`. Everything else belongs to the engine thread. Main writes that
/// state only while no engine thread exists (`stop` waits for it to end) and otherwise hands values
/// over with `onEngine`.
final class ScrollEngine: NSObject, @unchecked Sendable {
    var onPermissionLost: (@MainActor () -> Void)?

    private var loop: CFRunLoop?          // main: the engine thread's run loop while the tap runs
    private var ended: DispatchSemaphore? // main: signalled when that thread has finished

    // Engine thread from here on.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var health: Timer?
    private var link: CADisplayLink?
    private var settings = Settings()
    private var frontIsGame = false
    private var vertical = Axis(), horizontal = Axis()
    private var flags: CGEventFlags = []  // modifiers of the latest notch, for the frames it drives
    private var lastFrame = 0.0           // targetTimestamp of the latest frame

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            guard loop != nil else { return }
            let game = Self.isGame(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            onEngine { self.frontIsGame = game }
        }
        _ = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [self] _ in
            replaceLink()
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [self] _ in
            replaceLink()
        }
    }

    @discardableResult func apply(_ settings: Settings) -> Bool {
        guard settings.enabled && settings.scrollEnabled && AXIsProcessTrusted() else {
            stop()
            return false
        }
        guard loop == nil else {
            onEngine { self.settings = settings }
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
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, engine in
                Unmanaged<ScrollEngine>.fromOpaque(engine!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        self.settings = settings
        frontIsGame = Self.isGame(NSWorkspace.shared.frontmostApplication)
        vertical = Axis()  // forget what a stopped animation never posted
        horizontal = Axis()
        let started = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let thread = Thread { self.run(started, ended) }
        thread.name = "WinMouse scroll"
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
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
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
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return unchanged
        }
        guard type == .scrollWheel,
              // Trackpads, Magic Mouse and smooth-scrolling mouse drivers send pixels or phases.
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
              // Only wheels: remappers and automation post events without a sending device.
              event.getIntegerValueField(sender) != 0
        else { return unchanged }

        let up = notches(event, .scrollWheelEventDeltaAxis1)
        let left = notches(event, .scrollWheelEventDeltaAxis2)
        // Debug level: costs nothing unless someone streams it (`log stream --level debug ...`).
        log.debug("""
            wheel lines \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) \
            raw \(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)) \
            inverted \(isInvertedFromDevice(event)) sender \(event.getIntegerValueField(sender)) -> notches \(up), \(left)
            """)
        guard up != 0 || left != 0 else { return unchanged }
        let reverse = !settings.naturalDirection && isInvertedFromDevice(event)

        // Games and modifier gestures (zoom and the like) keep macOS behaviour apart from the
        // direction: smoothed pixel events break weapon and hotbar wheels (existing-apps.md §3.3).
        let flags = event.flags
        if frontIsGame || !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            if reverse { reverseDirection(event) }
            return unchanged
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
        return nil
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

    /// Main thread: whether the app declares itself a game in its Info.plist.
    private static func isGame(_ app: NSRunningApplication?) -> Bool {
        guard let url = app?.bundleURL,
              let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        else { return false }
        return category.contains("games")
    }
}

/// One axis: its animation and the whole points posted so far, so the sub-point rest carries over.
private struct Axis {
    var animation = WheelAnimation()
    var posted = 0.0

    mutating func step(at t: Double) -> Int32 {
        let step = (animation.position(at: t) - posted).rounded()
        posted += step
        return Int32(max(min(step, 1e6), -1e6))  // a frame never moves this far; just no trap
    }
}

private let log = Logger(subsystem: "io.github.anilmetin0.winmouse", category: "scroll")

/// CGEvent field 137, which NSEvent.isDirectionInvertedFromDevice reads (macos-hid.md §5.3).
private let directionInverted = CGEventField(rawValue: 137)!

/// Undocumented CGEvent field 87: registry ID of the HID service that sent the event, 0 for posted
/// events (macos-hid.md §5.1, §5.4).
private let sender = CGEventField(rawValue: 87)!

/// Signed notches on one axis of a discrete wheel event, in the direction macOS delivered it.
/// ponytail: DeltaAxis is already accelerated (macos-hid.md §1.1), so only its sign counts: one
/// notch per event. SDK 27's pre-acceleration RawDeltaAxis fields (§5.1) could count the two
/// notches a fast wheel packs into one report, but their units are unverified until a real wheel
/// is logged (the debug log prints them), and a wrong unit would multiply every notch.
func notches(_ event: CGEvent, _ delta: CGEventField) -> Double {
    Double(event.getIntegerValueField(delta).signum())
}

/// Whether Natural scrolling has already negated this event's deltas. Reading field 137 directly
/// keeps NSEvent out of the tap; the self-test fails if a macOS update moves it.
func isInvertedFromDevice(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(directionInverted) != 0
}

/// Negates both axes of an event in place and clears its inverted mark. Writing DeltaAxis makes
/// macOS recompute PointDeltaAxis at 8 pt per line, so the point field goes last (macos-hid.md
/// §5.2, existing-apps.md §2.6).
func reverseDirection(_ event: CGEvent) {
    func negate(_ lines: CGEventField, _ fixed: CGEventField, _ points: CGEventField) {
        let l = event.getIntegerValueField(lines), f = event.getDoubleValueField(fixed)
        let p = event.getIntegerValueField(points)
        event.setIntegerValueField(lines, value: -l)
        event.setDoubleValueField(fixed, value: -f)
        event.setIntegerValueField(points, value: -p)
    }
    negate(.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
    negate(.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
    event.setIntegerValueField(directionInverted, value: 0)
}

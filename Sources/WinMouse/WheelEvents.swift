import CoreGraphics

// Reading and rewriting CoreGraphics wheel events. Free functions, so the self-test can check the
// private fields against AppKit.

/// CGEvent field 137, which NSEvent.isDirectionInvertedFromDevice reads (macos-hid.md §5.3).
let directionInverted = CGEventField(rawValue: 137)!

/// Undocumented CGEvent field 87: registry ID of the HID service that sent the event, 0 for posted
/// events (macos-hid.md §5.1, §5.4).
let senderField = CGEventField(rawValue: 87)!

/// kCGScrollWheelEventRawDeltaAxis1 (field 178), the wheel delta before acceleration. Spelled by
/// number because older SDKs may not name it (macos-hid.md §5.1, availability unverified).
let rawDeltaAxis1 = CGEventField(rawValue: 178)!

/// Whether a wheel event is a classic notch from a device: trackpads, Magic Mouse and smooth-scrolling
/// mouse drivers send pixels or phases, and remappers and automation post events without a sender.
func isDeviceNotch(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        && event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
        && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
        && event.getIntegerValueField(senderField) != 0
}

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

/// One axis of the wheel animation and the whole points posted so far, so the sub-point rest
/// carries over from frame to frame.
struct WheelAxis {
    var animation = WheelAnimation()
    var posted = 0.0

    mutating func step(at t: Double) -> Int32 {
        let step = (animation.position(at: t) - posted).rounded()
        posted += step
        return Int32(max(min(step, 1e6), -1e6))  // a frame never moves this far; just no trap
    }
}

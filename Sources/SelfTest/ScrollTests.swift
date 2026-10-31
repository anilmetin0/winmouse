import AppKit

// The wheel against docs/research/windows-scroll.md: distance and duration (§2.1-2.2) and the
// Chromium vectors A-D (§6), which the appendix's Python model reproduces as well.

func scrollTests() {
    check(inverseDeltaDuration(100) == 0.2, "Tinv(100) = \(inverseDeltaDuration(100)) s, want 0.2")
    check(abs(inverseDeltaDuration(480) - 0.1) < 1e-12, "Tinv(480) = \(inverseDeltaDuration(480)) s, want 0.1")
    // Lines and characters share the factor, so this is also 3 characters per tilt.
    check(notchDistance(3) == 100, "3 lines = \(notchDistance(3)) pt, want 100")
    check(abs(notchDistance(1) - 33.33) < 0.01, "1 line = \(notchDistance(1)) pt, want 33.33")

    // Notches of 100 pt as (time s, direction); positions as (time ms, pt); end of the animation, ms.
    let tenNotches = (0..<10).map { (Double($0) * 0.03, 1.0) }
    let vectors: [(String, [(Double, Double)], [(Double, Double)], Double)] = [
        ("A", [(0, 1)], [(25, 3.1), (50, 12.9), (75, 29.3), (100, 50), (125, 70.7), (150, 87.1), (175, 96.9), (200, 100)], 200),
        ("B", [(0, 1), (0.05, 1), (0.1, 1)], [(50, 12.9), (100, 59.5), (150, 145.1), (200, 245.9), (250, 297.1)], 266.5),
        ("C", tenNotches, [(90, 65.2), (180, 358.5), (270, 706.2), (300, 808.4), (350, 944.4), (400, 996.6)], 421.7),
        ("D", [(0, 1), (0.06, -1)], [(30, 4.5), (60, 18.7), (90, 33.5), (120, 38.3), (150, 32.9), (200, 12.4), (300, 0)], 260),
    ]
    for (name, notches, marks, end) in vectors {
        var wheel = WheelAnimation()
        var pending = notches[...]
        for (ms, want) in marks {
            while let notch = pending.first, notch.0 <= ms / 1000 {
                wheel.notch(at: notch.0, distance: notch.1 * 100)
                pending.removeFirst()
            }
            let got = wheel.position(at: ms / 1000)
            check(abs(got - want) < 0.05, "vector \(name) at \(ms) ms: \(got) pt, want \(want)")
        }
        check(!wheel.isFinished(at: (end - 0.05) / 1000) && wheel.isFinished(at: (end + 0.05) / 1000),
              "vector \(name) should end at \(end) ms")
    }

    // The tap reads Natural scrolling from CGEvent field 137, the field behind
    // NSEvent.isDirectionInvertedFromDevice (macos-hid.md §5.3). This fails if macOS moves it.
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
    let before = event.flatMap { NSEvent(cgEvent: $0) }?.isDirectionInvertedFromDevice
    event?.setIntegerValueField(directionInverted, value: 1)
    let after = event.flatMap { NSEvent(cgEvent: $0) }?.isDirectionInvertedFromDevice
    check(before == false && after == true, "field 137 no longer sets isDirectionInvertedFromDevice")

    // Reversing negates every delta field AppKit reads and clears the mark.
    if let event {
        check(isInvertedFromDevice(event), "isInvertedFromDevice misses field 137")
        reverseDirection(event)
        let ns = NSEvent(cgEvent: event)
        check(!isInvertedFromDevice(event) && ns?.isDirectionInvertedFromDevice == false, "reverseDirection keeps the inverted mark")
        check(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1 && (ns?.scrollingDeltaY ?? 0) < 0,
              "reverseDirection: delta \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)), AppKit \(ns?.scrollingDeltaY ?? 0)")
        // A posted event has no sender, so the tap leaves it alone and never sees its own output.
        check(!isDeviceNotch(event), "a posted event counts as a device notch")
    }
}

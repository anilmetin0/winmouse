import Foundation

// Chrome and Edge wheel scrolling on Windows for one axis, in points (1 pt = 1 Windows DIP). A port
// of the reference model in docs/research/windows-scroll.md (appendix), which follows Chromium's
// ScrollOffsetAnimationCurve step by step: ease-in-out, inverse-delta duration, merged notches.

/// Points per notch for `count` lines (vertical) or characters (tilt): Chromium scrolls 100 DIP per
/// three lines and uses the same factor for characters (windows-scroll.md §2.1, §5).
func notchDistance(_ count: Int) -> Double { Double(count) * 100 / 3 }

/// Seconds for a segment that covers `distance` pt: 200 ms up to 120 pt, 100 ms from 480 pt, linear
/// in between (Chromium's kInverseDelta, windows-scroll.md §2.2).
func inverseDeltaDuration(_ distance: Double) -> Double { min(max(14 - abs(distance) / 60, 6), 12) / 60 }

/// Chromium's kEpsilon, used as 0.01 pt, 0.01 pt/s and 10 ms (windows-scroll.md §8).
private let epsilon = 0.01

/// CSS `cubic-bezier(x1, y1, x2, y2)`.
struct CubicBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }

    /// Progress at time fraction `x`.
    func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let t = solve(x)
        return ((ay * t + by) * t + cy) * t
    }

    /// Slope of progress over time fraction at `x`.
    func slope(_ x: Double) -> Double {
        let t = solve(min(max(x, 0), 1))
        let dx = (3 * ax * t + 2 * bx) * t + cx, dy = (3 * ay * t + 2 * by) * t + cy
        return dx == 0 && dy == 0 ? 0 : dy / dx
    }

    /// The curve parameter at time fraction `x`, by bisection: x grows with it because x1 and x2
    /// lie in [0, 1].
    private func solve(_ x: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<100 {
            let t = (lo + hi) / 2
            if ((ax * t + bx) * t + cx) * t < x { lo = t } else { hi = t }
        }
        return (lo + hi) / 2
    }
}

/// One axis of Chrome's wheel animation. Positions in pt, times in seconds.
struct WheelAnimation {
    private var start = 0.0, target = 0.0, startTime = 0.0, duration = 0.0
    private var curve = easeInOut(slope: 0)

    func position(at t: Double) -> Double {
        let x = duration > 0 ? (t - startTime) / duration : 1
        return x >= 1 ? target : x <= 0 ? start : start + (target - start) * curve.value(x)
    }

    func isFinished(at t: Double) -> Bool { t >= startTime + duration }

    /// Adds a notch of signed `distance` at time `t`. During a running segment the target moves on
    /// and a new segment starts from the current position and speed, as Chromium's UpdateTarget
    /// does (windows-scroll.md §2.3). Nothing is dropped, not even on a change of direction.
    mutating func notch(at t: Double, distance: Double) {
        guard !isFinished(at: t) else {
            start = target; target += distance; startTime = t
            duration = inverseDeltaDuration(distance); curve = easeInOut(slope: 0)
            return
        }
        let newTarget = target + distance, p = position(at: t), v = velocity(at: t)
        let delta = newTarget - p
        // 2.5 times what the current speed needs for the rest, but only while it heads there.
        let bound = abs(v) >= epsilon && delta / v > 0 ? 2.5 * delta / v : .infinity
        let length = min(inverseDeltaDuration(delta), bound)
        if abs(delta) < epsilon || length < epsilon {  // already there, or too little time: jump
            target = newTarget; duration = t - startTime
            return
        }
        curve = easeInOut(slope: v * length / delta)  // starts at the current speed
        start = p; target = newTarget; startTime = t; duration = length
    }

    /// Smooth scrolling off: the whole distance at once, as Chrome does when Windows animations are
    /// off (windows-scroll.md §2.4).
    mutating func jump(at t: Double, distance: Double) {
        target += distance; start = target; startTime = t; duration = 0
    }

    private func velocity(at t: Double) -> Double {
        let x = duration > 0 ? (t - startTime) / duration : 1
        return x >= 1 ? 0 : curve.slope(x) * (target - start) / duration
    }
}

/// `cubic-bezier(0.42, 0.42 × slope, 0.58, 1)`: CSS ease-in-out with the first control point scaled
/// so the curve starts at `slope` (windows-scroll.md §2.2-2.3).
private func easeInOut(slope: Double) -> CubicBezier {
    CubicBezier(0.42, 0.42 * min(max(slope, -1000), 1000), 0.58, 1)
}

import Foundation

// Windows' "Enhance pointer precision" curve and pointer speed slider as a transfer function from
// counts per HID report to points per report (docs/research/windows-pointer.md), and that function
// as an Apple acceleration table, which hidd evaluates on every report (macos-hid.md §1.4).
//
// Left out because a stateless table can't hold them: Windows' gain averaging when speed climbs
// into a higher segment (windows-pointer.md §1.6) and its per-axis sub-pixel remainder (§1.7).
// macOS also measures speed as floor(√(dx² + dy²)) instead of max + min/2, so a diagonal move looks
// up a speed up to 11.8 % lower (windows-pointer.md §1.2, macos-hid.md §1.4).

/// SmoothMouseXCurve and SmoothMouseYCurve points 1-4, the Windows 8/8.1/10/11 defaults as the
/// registry's exact 16.16 values; point 0 is (0, 0) (windows-pointer.md §1.3).
private let curveX = ([0x6E15, 0x1_4000, 0x3_DC29, 0x28_0000] as [Double]).map { $0 / 65536 }
private let curveY = ([0x1_11FD, 0x4_2400, 0x12_FC00, 0x1BB_C000] as [Double]).map { $0 / 65536 }

/// The slider's factor with Enhance pointer precision off, for MouseSensitivity 1...20 (§2).
func eppOffFactor(_ speed: Int) -> Double {
    speed <= 2 ? Double(speed) / 32 : speed <= 10 ? Double(speed - 2) / 8 : Double(speed - 6) / 4
}

/// Knots of the Windows function, a polyline from the origin whose last segment extends. EPP on:
/// counts = 3.5 × X and points = 0.8 × speed/10 × Y, which is Windows 8+ at 100 % scale; Windows
/// pixels at 100 % are emitted as macOS points (§1.4, §2, §6). EPP off: one straight line.
private func windowsKnots(speed: Int, epp: Bool) -> [(counts: Double, points: Double)] {
    guard epp else { return [(1, eppOffFactor(speed))] }
    let k = 0.8 * Double(speed) / 10
    return zip(curveX, curveY).map { (3.5 * $0, k * $1) }
}

/// Points per report for `counts` per report, interpolated between knots as Windows does (§1.5).
func windowsPoints(_ counts: Double, speed: Int, epp: Bool) -> Double {
    let knots = windowsKnots(speed: speed, epp: epp)
    var start = (counts: 0.0, points: 0.0)
    for (i, end) in knots.enumerated() {
        if counts <= end.counts || i == knots.count - 1 {
            return start.points + (end.points - start.points) / (end.counts - start.counts) * (counts - start.counts)
        }
        start = end
    }
    return 0
}

/// The index our table's one curve is filed under: 1.0 in 16.16. The mouse's index key holds the
/// same value, so the filter uses the curve unscaled (macos-hid.md §1.4).
let appleTableIndex: Int32 = 0x1_0000

/// `windowsPoints` as an Apple acceleration table for a mouse of `resolution` dpi (macos-hid.md §1.4):
/// big-endian 16.16, signature "@200", one curve. The filter turns a point (x, y) into
/// (x · resolution / 67 counts, y · 96 / 67 points), joins the points from the origin and extends
/// the last segment, so each knot is stored as x = counts · 67 / resolution, y = points · 67 / 96.
func appleTable(speed: Int, epp: Bool, resolution: Double) -> Data {
    // A far knot on the extended line keeps the extension exact in 16.16; EPP off needs only that.
    // ponytail: 1024 counts fits 16.16 for resolutions above 2 dpi; a lower one gets a clamped knot.
    let far = (counts: 1024.0, points: windowsPoints(1024, speed: speed, epp: epp))
    let knots = (epp ? windowsKnots(speed: speed, epp: true) : []) + [far]

    var table = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { table.append(contentsOf: $0) } }
    func fixed(_ value: Double) -> Int32 { Int32(min(max((value * 65536).rounded(), -2_147_483_648), 2_147_483_647)) }
    append(Int32(0x8000))                               // scale: unused by the filter; 0.5 like Apple's table
    table.append(contentsOf: [0x40, 0x32, 0x30, 0x30])  // "@200"
    append(UInt16(1))                                   // curves
    append(appleTableIndex)
    append(UInt16(knots.count))
    for knot in knots {
        append(fixed(knot.counts * 67 / resolution))
        append(fixed(knot.points * 67 / 96))
    }
    return table
}

/// Apple's built-in table, which the filter uses when a service has none (IOHIDFamily-2238.120.5,
/// IOHIDPointerScrollFilter.cpp:63-78). A mouse that had no table gets this one back, because a
/// property can't be removed from a service once it is set (macos-hid.md §3).
let appleDefaultTable = Data([
    0x00, 0x00, 0x80, 0x00,
    0x40, 0x32, 0x30, 0x30, 0x00, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x09, 0x00, 0x00, 0x71, 0x3B, 0x00, 0x00,
    0x60, 0x00, 0x00, 0x04, 0x4E, 0xC5, 0x00, 0x10,
    0x80, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x5F,
    0x00, 0x00, 0x00, 0x16, 0xEC, 0x4F, 0x00, 0x8B,
    0x00, 0x00, 0x00, 0x1D, 0x3B, 0x14, 0x00, 0x94,
    0x80, 0x00, 0x00, 0x22, 0x76, 0x27, 0x00, 0x96,
    0x00, 0x00, 0x00, 0x24, 0x62, 0x76, 0x00, 0x96,
    0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x96,
    0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x96,
    0x00, 0x00,
])

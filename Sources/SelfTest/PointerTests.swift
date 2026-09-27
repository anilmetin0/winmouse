import Foundation

// The pointer curve against docs/research/windows-pointer.md (§1.5 steady state, §2 slider), and
// our Apple table run through a re-implementation of the filter's table code (macos-hid.md §1.4).

func pointerTests() {
    // §1.5: points per report at speed 10; with EPP on the slider scales the output by speed/10 (§2).
    let row: [(counts: Double, points: Double)] = [
        (1, 0.569), (2, 1.280), (3, 2.136), (4, 2.992), (5, 4.125), (6, 5.425), (8, 8.025), (10, 10.625),
        (12, 13.225), (14, 16.504), (16, 21.877), (20, 32.623), (24, 43.369), (32, 64.860), (48, 107.844),
        (64, 150.828), (100, 247.541), (140, 355.000),
    ]
    for speed in [1, 10, 20] {
        for (counts, points) in row {
            let got = windowsPoints(counts, speed: speed, epp: true)
            check(abs(got * 10 / Double(speed) - points) < 0.0005,
                  "EPP on, speed \(speed), \(counts) counts: \(got) pt, want \(points * Double(speed) / 10)")
        }
    }

    // §2: the slider with EPP off, a plain factor.
    let factors: [Double] = [1 / 32, 1 / 16, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1,
                             1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.25, 3.5]
    for (i, factor) in factors.enumerated() {
        check(eppOffFactor(i + 1) == factor, "EPP off, speed \(i + 1): factor \(eppOffFactor(i + 1)), want \(factor)")
        check(windowsPoints(7, speed: i + 1, epp: false) == 7 * factor, "EPP off, speed \(i + 1): 7 counts")
    }

    // The parser reads Apple's own table as macos-hid.md §1.4 decodes it, so the layout it checks is real.
    let apple = parseAppleTable(appleDefaultTable)
    check(apple?.count == 2 && apple?[0].index == 0 && apple?[1].index == 1 && apple?[1].points.count == 9
          && apple?[1].points.last?.x == 40 && apple?[1].points.last?.y == 150,
          "Apple's default table does not parse as its two curves")

    // Our table through the filter's evaluation is the Windows function. The filter floors speed to
    // whole counts, so whole counts are all it ever looks up.
    for resolution in [400.0, 1000, 1600] {
        for epp in [true, false] {
            for speed in 1...20 {
                let what = "\(Int(resolution)) dpi, speed \(speed), EPP \(epp ? "on" : "off")"
                guard let curves = parseAppleTable(appleTable(speed: speed, epp: epp, resolution: resolution)),
                      curves.count == 1, curves[0].index == 1
                else {
                    check(false, "\(what): table is not one curve at index 1")
                    continue
                }
                let worst = (1...400).map { v in
                    abs(appleOutput(curves[0].points, Double(v), resolution: resolution)
                        - windowsPoints(Double(v), speed: speed, epp: epp))
                }.max() ?? .infinity
                check(worst < 1e-3, "\(what): table is off by \(worst) pt")
            }
        }
    }
}

/// Apple's table layout (IOHIDAccelerationTable.hpp:27-89): big-endian 16.16 scale, signature "@200"
/// or "USB*", curve count, then per curve its index, point count and (x, y) pairs.
private func parseAppleTable(_ data: Data) -> [(index: Double, points: [(x: Double, y: Double)])]? {
    let bytes = [UInt8](data)
    var at = 0
    func read(_ n: Int) -> UInt32? {
        guard at + n <= bytes.count else { return nil }
        defer { at += n }
        return bytes[at..<at + n].reduce(0) { $0 << 8 | UInt32($1) }
    }
    func fixed() -> Double? { read(4).map { Double(Int32(bitPattern: $0)) / 65536 } }

    guard read(4) != nil, let signature = read(4), signature == 0x4032_3030 || signature == 0x5553_422A,
          let count = read(2)
    else { return nil }
    var curves: [(index: Double, points: [(x: Double, y: Double)])] = []
    for _ in 0..<count {
        guard let index = fixed(), let n = read(2) else { return nil }
        var points: [(x: Double, y: Double)] = []
        for _ in 0..<n {
            guard let x = fixed(), let y = fixed() else { return nil }
            points.append((x, y))
        }
        curves.append((index, points))
    }
    return at == bytes.count ? curves : nil
}

/// IOHIDTableAcceleration for one curve used at its own index (IOHIDAccelerationAlgorithm.cpp:386-400,
/// 539-551): points mapped to (x · resolution / 67, y · 96 / 67), segments joined from the origin,
/// and the first segment that ends at or past `v` evaluated, else the last one.
private func appleOutput(_ points: [(x: Double, y: Double)], _ v: Double, resolution: Double) -> Double {
    var segments: [(m: Double, b: Double, end: Double)] = []
    var p0 = (x: 0.0, y: 0.0)
    for point in points.sorted(by: { $0.x < $1.x }) {
        let p1 = (x: point.x * (resolution / 67), y: point.y * (96.0 / 67))
        let m = (p1.y - p0.y) / (p1.x - p0.x)
        segments.append((m, p1.y - m * p1.x, p1.x))
        p0 = p1
    }
    guard let segment = segments.first(where: { !(v > $0.end) }) ?? segments.last else { return 0 }
    return segment.m * v + segment.b
}

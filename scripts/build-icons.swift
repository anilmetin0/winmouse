import AppKit
import Foundation

// The existing vector mark at native iconset sizes; the small variant drops the desk grid.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("build/WinMouse.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ pixels: Int, source: String, to url: URL) throws {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(source)),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fatalError("Could not render the WinMouse vector icon") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels, source: size <= 32 ? "docs/assets/icon-small.svg" : "docs/assets/icon.svg",
                   to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try render(1024, source: "docs/assets/icon.svg", to: root.appendingPathComponent("docs/assets/icon-1024.png"))
try render(256, source: "docs/assets/icon.svg", to: root.appendingPathComponent("docs/assets/icon.png"))
print("Rendered WinMouse.iconset and shared PNG assets")

let favicon = try String(contentsOf: root.appendingPathComponent("docs/assets/icon-small.svg"), encoding: .utf8)
    .replacingOccurrences(of: "viewBox=\"0 0 1024 1024\"", with: "viewBox=\"100 100 824 824\"")
try favicon.write(to: root.appendingPathComponent("docs/assets/favicon.svg"), atomically: true, encoding: .utf8)
try render(32, source: "docs/assets/favicon.svg", to: root.appendingPathComponent("docs/assets/favicon-32.png"))

import Foundation

/// Stable releases only; ordering must be numeric (0.10.0 is newer than 0.9.0).
struct ReleaseVersion: Comparable, Equatable, Sendable {
    let components: [Int]
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && (part.count == 1 || part.first != "0")
                && part.utf8.allSatisfy { (48...57).contains($0) } && Int(part) != nil
        }) else { return nil }
        components = parts.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let sha256: String
    let size: Int64
    let url: URL
    let releaseNotes: URL

    func validate() throws {
        guard ReleaseVersion(version) != nil, size > 0,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              url.absoluteString == "https://github.com/anilmetin0/winmouse/releases/download/v\(version)/WinMouse-\(version).dmg",
              releaseNotes.absoluteString == "https://github.com/anilmetin0/winmouse/releases/tag/v\(version)"
        else { throw UpdateFailure.invalidRelease }
    }
}

enum UpdateFailure: LocalizedError {
    case invalidRelease, download, checksum, wrongApp, readOnly, helper, parentStillRunning, homebrew, newerSystem
    var errorDescription: String? {
        switch self {
        case .invalidRelease: String(localized: "The update information is invalid. Your installed copy has not changed.")
        case .download: String(localized: "The update could not be downloaded. Check your connection and try again.")
        case .checksum: String(localized: "The downloaded file failed verification. Your installed copy has not changed.")
        case .wrongApp: String(localized: "The download does not contain the expected WinMouse version.")
        case .readOnly: String(localized: "WinMouse cannot update in this location. Move it to Applications or use Homebrew.")
        case .helper: String(localized: "The updater could not be started. Your installed copy has not changed.")
        case .parentStillRunning: String(localized: "WinMouse did not quit in time. The update was cancelled.")
        case .homebrew: String(localized: "Homebrew could not complete the update. Try brew upgrade --cask winmouse in Terminal.")
        case .newerSystem: String(localized: "This update requires a newer version of macOS.")
        }
    }
}

/// System tools only, with argument arrays rather than interpolated shell commands.
enum UpdateFiles {
    static let bundleID = "io.github.anilmetin0.winmouse"

    /// Respect Homebrew's receipt, including a custom --appdir; don't replace a managed app
    /// behind Homebrew's back. Configuration precedence matches Cask::Config.
    static func homebrew(for target: URL, prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]) -> URL? {
        for prefix in prefixes {
            let brew = prefix.appendingPathComponent("bin/brew")
            let receipt = prefix.appendingPathComponent("Caskroom/winmouse/.metadata/config.json")
            guard FileManager.default.isExecutableFile(atPath: brew.path),
                  let data = try? Data(contentsOf: receipt),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let directory = ["explicit", "env", "default"].compactMap { (config[$0] as? [String: Any])?["appdir"] as? String }.first ?? "/Applications"
            let app = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).appendingPathComponent("WinMouse.app")
            if app.standardizedFileURL == target.standardizedFileURL { return brew }
        }
        return nil
    }

    @discardableResult static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateFailure.wrongApp }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult static func runHomebrew(_ brew: URL, _ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        do { return try run(brew.path, arguments, environment: environment) }
        catch { throw UpdateFailure.homebrew }
    }

    static func verifyImage(_ image: URL, manifest: UpdateManifest) throws {
        try manifest.validate()
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == manifest.size else { throw UpdateFailure.checksum }
        let digest = try run("/usr/bin/shasum", ["-a", "256", image.path]).split(separator: " ").first
        guard digest.map(String.init) == manifest.sha256 else { throw UpdateFailure.checksum }
    }

    static func verifyApp(_ app: URL, version: String? = nil) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let actual = info["CFBundleShortVersionString"] as? String, ReleaseVersion(actual) != nil,
              version == nil || actual == version,
              let executable = info["CFBundleExecutable"] as? String, executable == "WinMouse",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/WinMouse").path)
        else { throw UpdateFailure.wrongApp }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard (1...3).contains(parts.count), numbers.count == parts.count,
                  numbers.allSatisfy({ $0 >= 0 }) else { throw UpdateFailure.wrongApp }
            let required = OperatingSystemVersion(majorVersion: numbers[0],
                minorVersion: numbers.count > 1 ? numbers[1] : 0, patchVersion: numbers.count > 2 ? numbers[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else { throw UpdateFailure.newerSystem }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// Same-volume bundle replacement, keeping the original until the new app has launched.
    static func replace(target: URL, candidate: URL) throws -> URL {
        let backup = "WinMouse.previous-\(UUID().uuidString).app"
        _ = try FileManager.default.replaceItemAt(target, withItemAt: candidate,
                    backupItemName: backup, options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        return target.deletingLastPathComponent().appendingPathComponent(backup)
    }
}

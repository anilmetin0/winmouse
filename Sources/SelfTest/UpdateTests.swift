import Foundation

func updateTests() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    check(updateCheckIsDue(last: nil, now: now), "first automatic check is due")
    check(!updateCheckIsDue(last: now.addingTimeInterval(-86399), now: now), "no duplicate daily checks")
    check(updateCheckIsDue(last: now.addingTimeInterval(-86400), now: now), "next daily check is due")
    check(updateCheckIsDue(last: now.addingTimeInterval(10), now: now), "recover from a backwards clock change")
    check(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!, "versions compare numerically")
    for text in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "1.2.-1", "1.2.3\n", "1.2.9999999999999999999999999"] {
        check(ReleaseVersion(text) == nil, "reject invalid stable version: \(text.debugDescription)")
    }
    let base = "https://github.com/anilmetin0/winmouse/releases"
    func manifest(url: String = "", version: String = "0.3.0", hash: String = String(repeating: "a", count: 64), size: Int64 = 3) -> UpdateManifest {
        UpdateManifest(version: version, sha256: hash, size: size,
            url: URL(string: url.isEmpty ? "\(base)/download/v\(version)/WinMouse-\(version).dmg" : url)!,
            releaseNotes: URL(string: "\(base)/tag/v\(version)")!)
    }
    do { try manifest().validate() } catch { check(false, "valid release rejected: \(error)") }
    for invalid in [manifest(url: "https://example.com/WinMouse-0.3.0.dmg"),
                    manifest(url: "http://github.com/anilmetin0/winmouse/releases/download/v0.3.0/WinMouse-0.3.0.dmg"),
                    manifest(version: "0.3.0-beta"), manifest(hash: "no_check"), manifest(size: 0)] {
        do { try invalid.validate(); check(false, "invalid release accepted") } catch {}
    }
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("WinMouse-update-tests-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }
        let image = work.appendingPathComponent("image.dmg")
        try Data("abc".utf8).write(to: image)
        let valid = manifest(hash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try UpdateFiles.verifyImage(image, manifest: valid)
        do { try UpdateFiles.verifyImage(image, manifest: manifest()); check(false, "corrupted image accepted") } catch {}
        do { try UpdateFiles.verifyImage(image, manifest: manifest(size: 4)); check(false, "wrong image size accepted") } catch {}

        let target = work.appendingPathComponent("Installed.app"), candidate = work.appendingPathComponent("Candidate.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
        let backup = try UpdateFiles.replace(target: target, candidate: candidate)
        check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new", "new bundle installed")
        check(try String(contentsOf: backup.appendingPathComponent("version"), encoding: .utf8) == "old", "old bundle retained until relaunch")
        _ = try fm.replaceItemAt(target, withItemAt: backup)
        check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "old", "failed launch can roll back")
        do {
            _ = try UpdateFiles.replace(target: target, candidate: work.appendingPathComponent("missing.app"))
            check(false, "missing candidate accepted")
        } catch {}
        check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "old", "failed update preserves original")

        let prefix = work.appendingPathComponent("brew"), appdir = work.appendingPathComponent("Custom Apps")
        try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let brew = prefix.appendingPathComponent("bin/brew")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let metadata = prefix.appendingPathComponent("Caskroom/winmouse/.metadata")
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["default": ["appdir": "/Applications"], "explicit": ["appdir": appdir.path]])
            .write(to: metadata.appendingPathComponent("config.json"))
        check(UpdateFiles.homebrew(for: appdir.appendingPathComponent("WinMouse.app"), prefixes: [prefix]) == brew,
              "Homebrew owns a matching custom app directory")
        check(UpdateFiles.homebrew(for: work.appendingPathComponent("WinMouse.app"), prefixes: [prefix]) == nil,
              "a separate manual copy is not treated as Homebrew-managed")

        let future = work.appendingPathComponent("Future.app")
        try fm.createDirectory(at: future.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = future.appendingPathComponent("Contents/MacOS/WinMouse")
        try Data().write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": UpdateFiles.bundleID, "CFBundleExecutable": "WinMouse",
                                  "CFBundleShortVersionString": "0.3.0", "LSMinimumSystemVersion": "999.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: future.appendingPathComponent("Contents/Info.plist"))
        do { try UpdateFiles.verifyApp(future); check(false, "incompatible macOS update accepted") }
        catch UpdateFailure.newerSystem {}  // rejected before replacement or launch
        catch { check(false, "wrong incompatibility error: \(error)") }
    } catch { check(false, "update integration test: \(error)") }
}

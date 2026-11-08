import AppKit
import SwiftUI

/// Checks only when asked. The app is untouched until its replacement has been verified.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case checking, current, available(UpdateManifest), downloading, installing, cancelling, failed(String)
    }
    @Published private(set) var phase: Phase = .current
    private var task: Task<Void, Never>?
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    var installing: Bool { phase == .installing }
    var busy: Bool { phase == .checking || phase == .downloading || phase == .installing || phase == .cancelling }
    var usesHomebrew: Bool { UpdateFiles.homebrew(for: Bundle.main.bundleURL) != nil }

    func cancelAndWait() async {
        let pending = task
        cancel()
        await pending?.value
        task = nil
    }

    func check() {
        guard !busy else { return }
        phase = .checking
        task = Task {
            defer { finishTask() }
            do {
                let endpoint = URL(string: "https://github.com/anilmetin0/winmouse/releases/latest/download/update.json")!
                var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("WinMouse/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024 else { throw UpdateFailure.download }
                let release = try JSONDecoder().decode(UpdateManifest.self, from: data)
                try release.validate()
                guard let installed = ReleaseVersion(Self.currentVersion), let latest = ReleaseVersion(release.version)
                else { throw UpdateFailure.invalidRelease }
                phase = latest > installed ? .available(release) : .current
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        guard !installing else { return }
        phase = task == nil ? .current : .cancelling
        task?.cancel()
    }

    private func finishTask() {
        if phase == .cancelling { phase = .current }
        task = nil
    }

    func install(_ release: UpdateManifest) {
        guard case .available = phase else { return }
        phase = .downloading
        task = Task {
            defer { finishTask() }
            var prepared: URL?
            var handedOff = false
            defer { if !handedOff, let prepared { try? FileManager.default.removeItem(at: prepared) } }
            do {
                try release.validate()
                let destination = Bundle.main.bundleURL
                let brew = UpdateFiles.homebrew(for: destination)
                if let brew {
                    // Refresh and fetch while WinMouse is still running; only the final upgrade
                    // needs the input engine to stop. Homebrew verifies its pinned checksum.
                    let fetching = Task.detached {
                        try UpdateFiles.runHomebrew(brew, ["update", "--quiet"])
                        try Task.checkCancellation()
                        try UpdateFiles.runHomebrew(brew, ["fetch", "--cask", "winmouse"])
                    }
                    _ = try await withTaskCancellationHandler(operation: { try await fetching.value },
                                                               onCancel: { fetching.cancel() })
                    try Task.checkCancellation()
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(".WinMouse-update-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    prepared = staging
                    try Self.copyHelper(to: staging)
                } else {
                    let (image, response) = try await URLSession.shared.download(from: release.url)
                    defer { try? FileManager.default.removeItem(at: image) }
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.download }
                    let preparation = Task.detached { try Self.prepare(image: image, release: release, target: destination) }
                    prepared = try await withTaskCancellationHandler(operation: { try await preparation.value },
                                                                     onCancel: { preparation.cancel() })
                }
                try Task.checkCancellation()
                guard let prepared else { throw UpdateFailure.helper }
                let helper = Process()
                helper.executableURL = prepared.appendingPathComponent("WinMouseUpdater")
                helper.arguments = [String(ProcessInfo.processInfo.processIdentifier), destination.path,
                                    prepared.path, release.version, brew?.path ?? ""]
                helper.standardInput = FileHandle.nullDevice
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                try helper.run()
                phase = .installing
                handedOff = true
                NSApp.terminate(nil)  // applicationWillTerminate restores HID and stops the tap
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private nonisolated static func prepare(image: URL, release: UpdateManifest, target: URL) throws -> URL {
        let fm = FileManager.default
        guard target.pathExtension == "app", !target.path.hasPrefix("/Volumes/"),
              fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw UpdateFailure.readOnly }
        try UpdateFiles.verifyApp(target)
        try UpdateFiles.verifyImage(image, manifest: release)
        try Task.checkCancellation()
        let staging = target.deletingLastPathComponent().appendingPathComponent(".WinMouse-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: staging) } }
        let mount = staging.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try UpdateFiles.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { _ = try? UpdateFiles.run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let source = mount.appendingPathComponent("WinMouse.app")
        try UpdateFiles.verifyApp(source, version: release.version)
        try Task.checkCancellation()
        let candidate = staging.appendingPathComponent("WinMouse.app")
        try UpdateFiles.run("/usr/bin/ditto", [source.path, candidate.path])
        try UpdateFiles.verifyApp(candidate, version: release.version)
        try copyHelper(to: staging)
        try Task.checkCancellation()
        succeeded = true
        return staging
    }

    private nonisolated static func copyHelper(to staging: URL) throws {
        let fm = FileManager.default
        guard let executable = Bundle.main.executableURL else { throw UpdateFailure.helper }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("WinMouseUpdater")
        try fm.copyItem(at: helper, to: staging.appendingPathComponent("WinMouseUpdater"))
        for language in ["en", "tr"] {
            if let resources = Bundle.main.url(forResource: language, withExtension: "lproj") {
                try fm.copyItem(at: resources, to: staging.appendingPathComponent("\(language).lproj"))
            }
        }
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                Text("WinMouse Updates").font(.title2.bold())
            }
            switch updater.phase {
            case .checking:
                ProgressView("Checking for updates…")
                Button("Cancel", action: close)
            case .current:
                Text("WinMouse \(Updater.currentVersion) is up to date")
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            case .available(let release):
                Text("WinMouse \(release.version) is available").font(.headline)
                Text("Installed version: \(Updater.currentVersion)").foregroundStyle(.secondary)
                Link("Release Notes", destination: release.releaseNotes)
                if updater.usesHomebrew {
                    Text("Homebrew will update this copy and restart WinMouse. macOS may ask you to allow Accessibility again.")
                } else {
                    Text("WinMouse will download the update, verify it, and restart. macOS may ask you to allow Accessibility again.")
                }
                HStack {
                    Button("Later", action: close)
                    Button("Install and Relaunch") { updater.install(release) }.keyboardShortcut(.defaultAction)
                }
            case .downloading:
                ProgressView("Downloading and verifying the update…")
                Button("Cancel", action: close)
            case .installing:
                ProgressView("Installing the update…")
            case .cancelling:
                ProgressView("Cancelling the update…")
            case .failed(let message):
                Text("Could not update WinMouse").font(.headline)
                Text(message).textSelection(.enabled)
                HStack {
                    Button("Close", action: close)
                    Button("Try Again") { updater.check() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

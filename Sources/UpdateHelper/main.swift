import AppKit
import Foundation

/// A separate process waits until normal application termination has restored mouse state.
@main
struct UpdateHelper {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 6, let parent = Int32(args[1]), parent > 1, ReleaseVersion(args[4]) != nil else { exit(1) }
        let target = URL(fileURLWithPath: args[2]), work = URL(fileURLWithPath: args[3])
        let brew = args[5].isEmpty ? nil : URL(fileURLWithPath: args[5])
        guard target.pathExtension == "app", work.lastPathComponent.hasPrefix(".WinMouse-update-"),
              brew != nil || work.deletingLastPathComponent() == target.deletingLastPathComponent() else { exit(1) }
        if let brew, UpdateFiles.homebrew(for: target) != brew { exit(1) }
        let candidate = work.appendingPathComponent("WinMouse.app")
        var backup: URL?
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let deadline = Date().addingTimeInterval(30)
            while kill(parent, 0) == 0 {
                guard Date() < deadline else { throw UpdateFailure.parentStillRunning }
                try await Task.sleep(for: .milliseconds(100))
            }
            try UpdateFiles.verifyApp(target)
            if let brew {
                do {
                    try UpdateFiles.runHomebrew(brew, ["upgrade", "--cask", "winmouse"])
                    try UpdateFiles.verifyApp(target, version: args[4])
                } catch { throw UpdateFailure.homebrew }
            } else {
                try UpdateFiles.verifyApp(candidate, version: args[4])
                backup = try UpdateFiles.replace(target: target, candidate: candidate)
            }
            let config = NSWorkspace.OpenConfiguration()
            _ = try await NSWorkspace.shared.openApplication(at: target, configuration: config)
            if let backup { try? FileManager.default.removeItem(at: backup) }
        } catch {
            var message = error.localizedDescription
            if let backup {
                // Put the original back if the new copy could not be opened.
                do { _ = try FileManager.default.replaceItemAt(target, withItemAt: backup) }
                catch {
                    message = String(format: String(localized: "The update failed. Your previous copy is saved at %@."), backup.path)
                }
            }
            _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.icon = NSImage(contentsOf: target.appendingPathComponent("Contents/Resources/AppIcon.icns"))
            alert.messageText = String(localized: "Could not update WinMouse")
            alert.informativeText = message
            NSApp.activate()
            alert.runModal()
        }
    }
}

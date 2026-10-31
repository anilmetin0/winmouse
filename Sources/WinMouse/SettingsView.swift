import ServiceManagement
import SwiftUI

/// The Windows mouse settings, by their Windows names and defaults, laid out like System Settings.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let openAccessibilitySettings: () -> Void

    // Defaults match Settings.swift, which registers the same defaults at launch.
    @AppStorage(Settings.Key.enabled) private var enabled = true
    @AppStorage(Settings.Key.pointerEnabled) private var pointerEnabled = true
    @AppStorage(Settings.Key.pointerSpeed) private var pointerSpeed = 10
    @AppStorage(Settings.Key.enhancePointerPrecision) private var enhancePointerPrecision = true
    @AppStorage(Settings.Key.scrollEnabled) private var scrollEnabled = true
    @AppStorage(Settings.Key.scrollLines) private var scrollLines = 3
    @AppStorage(Settings.Key.scrollChars) private var scrollChars = 3
    @AppStorage(Settings.Key.smoothScrolling) private var smoothScrolling = true
    @AppStorage(Settings.Key.naturalDirection) private var naturalDirection = false
    @AppStorage(Settings.Key.sideButtons) private var sideButtons = true
    @AppStorage(Settings.Key.controlZoom) private var controlZoom = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            if !state.rivals.isEmpty {
                Section {
                    Label(String(localized: "Another app is changing the mouse: \(ListFormatter.localizedString(byJoining: state.rivals)). Quit it so the two apps don't undo each other's settings."),
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }

            if !enabled {
                Section {
                    LabeledContent("WinMouse is paused.") {
                        Button("Resume") { enabled = true }
                    }
                }
            }

            Section {
                Toggle("Windows pointer movement", isOn: $pointerEnabled)
                Group {
                    Slider(value: speed, in: 1...20, step: 1) {
                        Text("Pointer speed")
                    } minimumValueLabel: {
                        Text("Slow")
                    } maximumValueLabel: {
                        Text("Fast")
                    }
                    Toggle("Enhance pointer precision", isOn: $enhancePointerPrecision)
                }
                .disabled(!pointerEnabled)
            } header: {
                Text("Pointer")
            } footer: {
                if enabled && pointerEnabled {
                    Text(miceSummary).foregroundStyle(.secondary)
                }
            }

            if enabled && state.needsAccessibility {
                Section {
                    LabeledContent {
                        Button("Open System Settings…", action: openAccessibilitySettings)
                    } label: {
                        Label("The wheel and the side buttons need Accessibility access.", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }

            Section("Wheel") {
                Toggle("Windows scrolling", isOn: $scrollEnabled)
                Group {
                    LabeledContent("Lines to scroll at a time") {
                        Text(scrollLines, format: .number).monospacedDigit()
                        Stepper("Lines to scroll at a time", value: $scrollLines, in: 1...100).labelsHidden()
                    }
                    LabeledContent("Characters to scroll horizontally") {
                        Text(scrollChars, format: .number).monospacedDigit()
                        Stepper("Characters to scroll horizontally", value: $scrollChars, in: 1...100).labelsHidden()
                    }
                    Toggle("Smooth scrolling", isOn: $smoothScrolling)
                    Picker("Scrolling direction", selection: $naturalDirection) {
                        Text("Down motion scrolls down").tag(false)
                        Text("Same as trackpad").tag(true)
                    }
                    Toggle("Control + wheel zooms", isOn: $controlZoom)
                }
                .disabled(!scrollEnabled)
            }

            Section {
                Toggle("Side buttons go back and forward", isOn: $sideButtons)
            } header: {
                Text("Buttons")
            } footer: {
                Text("Finder, Safari and other Apple apps go back and forward too. Games keep their own buttons.").foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Windows stores the speed as an integer 1...20; the slider works in Double.
    private var speed: Binding<Double> {
        Binding(get: { Double(pointerSpeed) }, set: { pointerSpeed = Int($0.rounded()) })
    }

    private var miceSummary: String {
        state.mice.isEmpty
            ? String(localized: "No external mouse connected.")
            : String(localized: "Applies to \(ListFormatter.localizedString(byJoining: state.mice)).")
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        if on {
            try? service.register()
        } else {
            try? service.unregister()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        // Waiting for approval counts as on, or the toggle would flip back and withdraw the request.
        openAtLogin = service.status == .enabled || service.status == .requiresApproval
    }
}

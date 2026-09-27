import AppKit
import IOKit
import IOKit.hidsystem
import OSLog

/// The Windows pointer curve on every external mouse. Each mouse's HID service gets `appleTable` and
/// an acceleration type of its own, and hidd's IOHIDPointerScrollFilter runs the curve on every report,
/// so the app costs nothing while the mouse moves and needs no permission (docs/research/macos-hid.md
/// §1-§3). Nothing goes to preferences: the values live in the service until the mouse is unplugged or
/// the Mac restarts. What a service had before is kept here and in the service itself, so the next
/// launch can undo a run that crashed.
@MainActor
final class PointerController {
    /// Product names of the mice that have the Windows curve now.
    private(set) var mice: [String] = []
    var onMiceChange: (@MainActor () -> Void)?

    private var settings = Settings(enabled: false)  // until the first `apply`
    private var sessionActive = true                 // false while another user has the screen
    private var driven: [UInt64: (originals: Originals, name: String)] = [:]  // by registry ID
    private var series = 0                           // the latest burst of passes; older ones stop

    init() {
        // ponytail: never unregistered, because the controller lives as long as the app.
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, .main)
            let me = Unmanaged.passUnretained(self).toOpaque()
            for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let added = IOServiceAddMatchingNotification(port, kind, mouseMatching(), { context, services in
                    drain(services)
                    let controller = Unmanaged<PointerController>.fromOpaque(context!).takeUnretainedValue()
                    MainActor.assumeIsolated { controller.rescanSoon() }
                }, me, &iterator)
                if added == KERN_SUCCESS { drain(iterator) }  // arms it; `apply` makes the first pass
            }
        }

        let events: [(Notification.Name, @MainActor @Sendable (PointerController) -> Void)] = [
            (NSWorkspace.didWakeNotification, { $0.rescanSoon() }),
            // Fast user switching: the services are shared, so the other user gets macOS behaviour.
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false; $0.restoreAll() }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true; $0.rescanSoon() }),
        ]
        for (name, action) in events {
            _ = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
    }

    func apply(_ settings: Settings) {
        self.settings = settings
        rescanSoon()  // a burst, so a mouse that hidd is still building at launch gets the curve too
    }

    func restoreAll() {
        series += 1  // pending passes would put the curve back
        if let lookup = serviceLookup() {
            for (id, entry) in driven {
                if let service = lookup(id) { restore(service, entry.originals) }
            }
        }
        driven = [:]
        publish()
    }

    /// Five passes over 2.5 s: a new service is in IOKit before hidd has built its filter, and after
    /// wake the mice come back one by one. Passes are idempotent, and nothing runs between bursts.
    private func rescanSoon() {
        series += 1
        let current = series
        for delay in [0, 0.25, 0.75, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.series == current else { return }
                    self.rescan()
                }
            }
        }
    }

    /// One pass: undo what a crashed run left, then give each mouse the curve or its own values back.
    private func rescan() {
        // In a session in the background, another user's WinMouse owns the mice: its backups would
        // look like a crashed run of ours and get undone.
        guard sessionActive, let lookup = serviceLookup() else { return }
        let wanted = settings.enabled && settings.pointerEnabled && sessionActive
        var next: [UInt64: (originals: Originals, name: String)] = [:]
        for id in mouseServiceIDs() {
            guard let service = lookup(id) else { continue }  // hidd hasn't built it yet
            var entry = driven[id]
            if entry == nil, let leftover = Originals(leftOn: service) {
                restore(service, leftover)
            }
            guard wanted else {
                if let entry { restore(service, entry.originals) }
                continue
            }
            if entry == nil, isExternalMouse(service) {
                entry = (Originals(service), property(service, "Product") as? String ?? String(localized: "Mouse"))
            }
            if let entry {
                if drive(service, entry.originals) {
                    next[id] = entry
                } else {
                    log.error("\(entry.name, privacy: .public): hidd refused the curve, left as it was")
                }
            }
        }
        driven = next
        publish()
    }

    /// Gives `service` the Windows curve unless it has it already (macos-hid.md §2.3). When hidd
    /// refuses a write, the service gets its own values back and this returns false.
    private func drive(_ service: IOHIDServiceClient, _ originals: Originals) -> Bool {
        // The filter falls back to 400 dpi as well (IOHIDPointerScrollFilter.cpp:804-812).
        let fixed = (property(service, "HIDPointerResolution") as? NSNumber)?.int32Value ?? 0
        let resolution = fixed > 0 ? Double(fixed) / 65536 : 400
        let table = appleTable(speed: settings.pointerSpeed, epp: settings.enhancePointerPrecision, resolution: resolution)
        if property(service, typeKey) as? String == indexKey,
           property(service, tableKey) as? Data == table,
           (property(service, indexKey) as? NSNumber)?.int32Value == appleTableIndex,
           (property(service, algorithmKey) as? NSNumber)?.int32Value == 0 {
            return true
        }
        log.info("\(property(service, "Product") as? String ?? "?", privacy: .public): Windows curve, speed \(self.settings.pointerSpeed), precision \(self.settings.enhancePointerPrecision), \(resolution) dpi")
        // The backup first, so a crash after any later write can be undone. The index before the
        // type that points the filter at it, and the algorithm last, because setting it rebuilds the
        // filter's curve from everything else.
        guard set(service, backupKey, originals.backup),
              set(service, indexKey, NSNumber(value: appleTableIndex)),
              set(service, tableKey, table as CFData),
              set(service, typeKey, indexKey as CFString),
              set(service, algorithmKey, NSNumber(value: Int32(0)))  // table
        else {
            restore(service, originals)
            return false
        }
        return true
    }

    /// Puts back what `drive` changed (macos-hid.md §3). A key can't be removed from a service, so a
    /// missing table comes back as Apple's built-in one and a missing algorithm as 2 (default), which
    /// the filter treats like absent ones. Our index key stays behind, read by nothing.
    private func restore(_ service: IOHIDServiceClient, _ originals: Originals) {
        _ = set(service, tableKey, (originals.table ?? appleDefaultTable) as CFData)
        _ = set(service, typeKey, mouseType as CFString)
        _ = set(service, algorithmKey, NSNumber(value: originals.algorithm ?? 2))  // last: rebuilds the curve
        _ = set(service, backupKey, NSDictionary())  // not ours any more
    }

    private func publish() {
        // ponytail: names only, so two identical mice show once.
        let names = Set(driven.values.map { $0.name }).sorted()
        guard names != mice else { return }
        mice = names
        onMiceChange?()
    }
}

private let log = Logger(subsystem: "io.github.anilmetin0.winmouse", category: "pointer")

private let typeKey = "HIDPointerAccelerationType"
private let mouseType = "HIDMouseAcceleration"
private let tableKey = "HIDPointerAccelerationTable"
private let algorithmKey = "HIDPointerAccelerationAlgorithm"  // 0 table, 1 parametric, 2 default (IOHIDKeys.h)
/// Keep the original HID keys across the app rename so a prior installation's backup can be restored.
/// With the type pointing here, System Settings' tracking speed and its "Pointer
/// acceleration" switch, which act on HIDMouseAcceleration, no longer reach the mouse (macos-hid.md §2.3).
private let indexKey = "NewMouseAcceleration"
/// A service's values from before `drive`, kept in the service so the next launch can undo a crashed run.
private let backupKey = "NewMouseOriginal"

/// What `drive` changes on a service, as it was before (macos-hid.md §3). The acceleration type
/// isn't kept: only services of type HIDMouseAcceleration are driven.
private struct Originals {
    var table: Data?       // nil: none, so the filter used Apple's built-in table
    var algorithm: Int32?  // nil: no override

    /// As `service` has them now.
    init(_ service: IOHIDServiceClient) {
        table = validTable(property(service, tableKey))
        algorithm = validAlgorithm(property(service, algorithmKey))
    }

    /// What a crashed run left on `service`: its backup, or Apple's defaults if only our type is there.
    /// Nil when the service isn't ours.
    init?(leftOn service: IOHIDServiceClient) {
        if let backup = property(service, backupKey) as? [String: Any], backup[typeKey] as? String == mouseType {
            table = validTable(backup[tableKey])
            algorithm = validAlgorithm(backup[algorithmKey])
        } else if property(service, typeKey) as? String == indexKey {
            table = nil
            algorithm = nil
        } else {
            return nil
        }
    }

    /// The backup for the service. Its type entry keeps it non-empty; an empty one means "not ours".
    var backup: CFDictionary {
        var backup: [String: Any] = [typeKey: mouseType]
        backup[tableKey] = table
        backup[algorithmKey] = algorithm
        return backup as CFDictionary
    }
}

/// `value` if it is a table the filter accepts (macos-hid.md §1.4), else nil.
private func validTable(_ value: Any?) -> Data? {
    guard let table = value as? Data, table.count > 10,
          [[0x40, 0x32, 0x30, 0x30], [0x55, 0x53, 0x42, 0x2A]].contains([UInt8](table.dropFirst(4).prefix(4)))
    else { return nil }
    return table
}

/// `value` if it is a CFNumber naming an algorithm the filter knows, else nil.
private func validAlgorithm(_ value: Any?) -> Int32? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
          (0...2).contains(number.int32Value)
    else { return nil }
    return number.int32Value
}

/// External mice only, judged as hidd sees the service: a Generic Desktop / Mouse usage, as the filter
/// itself matches; the built-in trackpad reports one too but is Built-In; trackpads use their own
/// acceleration type (macos-hid.md §1.1, §4).
private func isExternalMouse(_ service: IOHIDServiceClient) -> Bool {
    IOHIDServiceClientConformsTo(service, 1, 2) != 0
        && (property(service, "Built-In") as? NSNumber)?.boolValue != true
        && property(service, typeKey) as? String == mouseType
}

private func property(_ service: IOHIDServiceClient, _ key: String) -> CFTypeRef? {
    IOHIDServiceClientCopyProperty(service, key as CFString)
}

/// Writes one property after checking its CF type, because a value of the wrong type can crash hidd
/// or WindowServer (macos-hid.md §2.3).
private func set(_ service: IOHIDServiceClient, _ key: String, _ value: CFTypeRef) -> Bool {
    let expected = switch key {
    case typeKey: CFStringGetTypeID()
    case tableKey: CFDataGetTypeID()
    case backupKey: CFDictionaryGetTypeID()
    default: CFNumberGetTypeID()  // the algorithm and our index
    }
    return CFGetTypeID(value) == expected && IOHIDServiceClientSetProperty(service, key as CFString, value)
}

/// HID event services with a Generic Desktop / Mouse usage pair, which IOHIDEventService matches
/// against its DeviceUsagePairs (IOHIDFamilyPrivate.cpp, CompareDeviceUsage). The built-in trackpad
/// is among them; `isExternalMouse` leaves it out.
private func mouseMatching() -> CFDictionary {
    ["IOProviderClass": "IOHIDEventService", "DeviceUsagePage": 1, "DeviceUsage": 2] as NSDictionary
}

/// Registry IDs of those services; hidd's service for a device carries the same ID.
private func mouseServiceIDs() -> [UInt64] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, mouseMatching(), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var ids: [UInt64] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        var id: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { ids.append(id) }
        IOObjectRelease(entry)
    }
    return ids
}

/// Empties an IOKit notification iterator, which arms the notification again.
private func drain(_ iterator: io_iterator_t) {
    while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
}

private typealias CreateClient = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?
private typealias CopyService = @convention(c) (IOHIDEventSystemClient, UInt64) -> Unmanaged<IOHIDServiceClient>?

/// Finds hidd's service for a registry ID. Private SPI, looked up at run time so a macOS without it
/// leaves the mice alone. Client type 2 (passive) is what System Settings' Mouse pane and IOKit's own
/// IOHIDSetParameter create; the public simple client may not set tables (macos-hid.md §2.2). A fresh
/// client per pass, because hidd may have restarted since the last one.
private func serviceLookup() -> ((UInt64) -> IOHIDServiceClient?)? {
    let everywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let create = dlsym(everywhere, "IOHIDEventSystemClientCreateWithType").map({ unsafeBitCast($0, to: CreateClient.self) }),
          let copy = dlsym(everywhere, "IOHIDEventSystemClientCopyServiceForRegistryID").map({ unsafeBitCast($0, to: CopyService.self) }),
          let client = create(kCFAllocatorDefault, 2, nil)?.takeRetainedValue()
    else { return nil }
    return { copy(client, $0)?.takeRetainedValue() }
}

import AppKit
import ApplicationServices

// Read-only capability probe: every event is passed through unchanged.
print("Accessibility trusted: \(AXIsProcessTrusted())")
print("Event listening: \(CGPreflightListenEventAccess()), event control: \(CGPreflightPostEventAccess())")
for (name, location) in [("HID", CGEventTapLocation.cghidEventTap), ("Session", .cgSessionEventTap)] {
    let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue,
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    print("\(name): created=\(tap != nil), enabled=\(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)")
    if let tap { CFMachPortInvalidate(tap) }
}

// Optionally inspect one running process's registered tap, without capturing
// or posting input. This distinguishes a created port from the subscribed mask.
if let argument = CommandLine.arguments.dropFirst().first, let pid = Int32(argument) {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success else { exit(1) }
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &taps, &count) == .success else { exit(1) }
    for tap in taps.prefix(Int(count)) where tap.tappingProcess == pid {
        print("Process \(pid): id=\(tap.eventTapID), location=\(tap.tapPoint.rawValue), options=\(tap.options.rawValue), mask=\(tap.eventsOfInterest), enabled=\(tap.enabled)")
    }
}

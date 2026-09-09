import AppKit
@main struct DimmingSmoke {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  app.finishLaunching()
  guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.brightnessDisplayID) == 0 && CGDisplayIsInMirrorSet($0.brightnessDisplayID) == 0 }) else { print("SKIP: no independent external display"); return }
  let hardware = DelayedHardware()
  let controller = ExternalBrightnessController(hardware: hardware)
  var factors: [Double] = []
  controller.onSoftwareBrightness = { id, factor in
   precondition(id == screen.brightnessDisplayID)
   factors.append(factor)
  }
  precondition(controller.write(90, to: screen.brightnessDisplayID))
  precondition(factors == [0.9])
  precondition(controller.read(screen.brightnessDisplayID) == 90)
  precondition(hardware.writes.isEmpty)
  hardware.available = true
  controller.refreshPendingHardware()
  precondition(hardware.writes == [90])
  precondition(controller.read(screen.brightnessDisplayID) == 90)
  controller.close()
  precondition(factors.last == 1)
  print("PASS: targeted gamma intent, delayed hardware replay, value readback, restoration intent")
 }
}

@MainActor final class DelayedHardware: DisplayBrightnessHardware {
 var available = false
 var value = 100.0
 var writes: [Double] = []
 func read(_ id: UInt32) -> Double? { available ? value : nil }
 func write(_ percentage: Double, to id: UInt32) -> Bool { guard available else { return false }; writes.append(percentage); value = percentage; return true }
}

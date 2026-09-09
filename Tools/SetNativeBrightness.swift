import Foundation

// Test utility: a single explicitly requested native adjustment, for checking
// coexistence with brightness changes that bypass the app's event tap.
@main struct SetNativeBrightness {
    static func main() throws {
        guard let argument = CommandLine.arguments.dropFirst().first, let value = Float(argument), value.isFinite, (0...1).contains(value) else { exit(2) }
        let panel = try XDRNativePanel.open()
        try panel.setBrightness(value)
    }
}

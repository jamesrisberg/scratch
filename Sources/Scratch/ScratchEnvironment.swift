import Foundation
import ScratchKit

/// Isolation switches for tests and parallel instances:
///
/// - `SCRATCH_HOME`: base directory (pads in `<home>/pads`, settings in `<home>/preferences.json`,
///   the `menuBar.consumed` opt-out in `<home>/menubar.json`);
///   default `~/Library/Application Support/Scratch`. An isolated instance also keeps its panel
///   frames apart from the real one's.
/// - `SCRATCH_SOCKET`: socket name under MacHUD's sockets directory; default `scratch`.
/// - `SCRATCH_NO_HOTKEYS`: set to skip registering the global hotkeys.
enum ScratchEnvironment {
    static let environment = ProcessInfo.processInfo.environment

    static var isolatedHome: String? {
        environment["SCRATCH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var baseDirectory: URL {
        if let home = isolatedHome {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return PadStore.defaultBaseDirectory
    }

    static var padsDirectory: URL { PadStore.padsDirectory(base: baseDirectory) }
    static var settingsURL: URL { baseDirectory.appendingPathComponent("preferences.json") }

    /// Where panel frames are remembered: the app's defaults, or a separate suite when
    /// `SCRATCH_HOME` isolates this instance (so a test run never moves the real panel).
    static let defaults: UserDefaults = isolatedHome == nil
        ? .standard
        : UserDefaults(suiteName: "xyz.machud.scratch.isolated") ?? .standard

    static func socketName(default name: String) -> String {
        environment["SCRATCH_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    static var hotKeysEnabled: Bool { environment["SCRATCH_NO_HOTKEYS"] == nil }
}

import Foundation
import XCTest
@testable import ScratchKit

/// A throwaway directory under the temporary folder, removed in tearDown.
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// A controllable clock.
final class Clock {
    var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_790_000_000)) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    var now: () -> Date { { self.date } }
}

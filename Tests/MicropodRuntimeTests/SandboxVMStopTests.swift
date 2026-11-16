import XCTest

@testable import MicropodRuntime

final class SandboxVMStopTests: XCTestCase {
    actor Calls {
        var value = 0
        func increment() { value += 1 }
    }
    struct Refused: Error {}

    func testConcurrentStopsJoinOneOperation() async throws {
        let stop = SandboxVMStop()
        let calls = Calls()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try await stop.run { await calls.increment() } }
            }
            try await group.waitForAll()
        }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testFailedStopIsNotSilentlyReplayed() async {
        let stop = SandboxVMStop()
        let calls = Calls()
        for _ in 0..<2 {
            do {
                try await stop.run {
                    await calls.increment()
                    throw Refused()
                }
                XCTFail("refused stop reported success")
            } catch is Refused {
            } catch { XCTFail("unexpected error: \(error)") }
        }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }
}

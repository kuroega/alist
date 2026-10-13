import XCTest
@testable import AListTV

final class TMDBRequestGateTests: XCTestCase {
    private actor Counter {
        private(set) var running = 0
        private(set) var peak = 0
        private(set) var calls = 0

        func start() {
            calls += 1
            running += 1
            peak = max(peak, running)
        }

        func finish() { running -= 1 }
    }

    func testNeverRunsMoreThanTheLimit() async throws {
        let gate = TMDBRequestGate(limit: 3)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    try await gate.run(key: "request-\(index)") {
                        await counter.start()
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.finish()
                        return Data()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        let calls = await counter.calls
        XCTAssertEqual(calls, 12)
        XCTAssertEqual(peak, 3, "Every slot is used, and no more")
    }

    func testConcurrentIdenticalRequestsShareOneFetch() async throws {
        let gate = TMDBRequestGate(limit: 4)
        let counter = Counter()
        let replies = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    try await gate.run(key: "same") {
                        await counter.start()
                        try await Task.sleep(for: .milliseconds(50))
                        return Data("reply".utf8)
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(replies, Array(repeating: Data("reply".utf8), count: 5))
    }

    func testFailuresReachEveryWaiterAndFreeTheSlot() async throws {
        let gate = TMDBRequestGate(limit: 1)
        do {
            _ = try await gate.run(key: "broken") { throw TMDBError.notFound }
            XCTFail("Expected the error to propagate")
        } catch {
            XCTAssertEqual(error as? TMDBError, .notFound)
        }
        let data = try await gate.run(key: "next") { Data("ok".utf8) }
        XCTAssertEqual(data, Data("ok".utf8))
    }
}

import XCTest
@testable import FreeMacMonitor

final class MetricsMathTests: XCTestCase {

    // MARK: - MemoryBreakdown

    func testMemoryBreakdownMath() {
        let mb = MemoryBreakdown(total: 1000, app: 300, wired: 100, compressed: 100, cached: 200, free: 300)
        XCTAssertEqual(mb.used, 700)
        XCTAssertEqual(mb.pressure, 50.0, accuracy: 0.0001)   // (300+100+100)/1000
        XCTAssertEqual(mb.headroom, 70.0, accuracy: 0.0001)   // (300+100+100+200)/1000
    }

    func testMemoryBreakdownZeroTotalDoesNotDivide() {
        let mb = MemoryBreakdown(total: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: 0)
        XCTAssertEqual(mb.pressure, 0)
        XCTAssertEqual(mb.headroom, 0)
    }

    // MARK: - normalizedBreakdown (raw VM counters → display buckets)

    func testNormalizedBreakdownSumsToTotal() {
        let mb = SystemMetrics.normalizedBreakdown(
            total: 1000, rawApp: 300, rawWired: 100, rawCompressed: 100, rawCached: 200)
        XCTAssertEqual(mb.total, 1000)
        XCTAssertEqual(mb.app + mb.wired + mb.compressed + mb.cached + mb.free, 1000)
        XCTAssertEqual(mb.app, 300)
        XCTAssertEqual(mb.wired, 100)
        XCTAssertEqual(mb.compressed, 100)
        XCTAssertEqual(mb.cached, 200)
        XCTAssertEqual(mb.free, 300)
    }

    func testNormalizedBreakdownCapsOverlappingCounters() {
        // Counters overlap (cached pages also counted elsewhere): raw buckets
        // can sum well beyond physical RAM.  Non-reclaimable buckets are
        // reserved first, cache is capped, and the residual lands in `free`.
        let mb = SystemMetrics.normalizedBreakdown(
            total: 100, rawApp: 90, rawWired: 30, rawCompressed: 20, rawCached: 60)
        XCTAssertEqual(mb.app + mb.wired + mb.compressed + mb.cached + mb.free, 100)
        XCTAssertEqual(mb.app, 90)
        XCTAssertEqual(mb.wired, 10)        // only 10 left after app
        XCTAssertEqual(mb.compressed, 0)    // nothing left after wired
        XCTAssertEqual(mb.cached, 0)
        XCTAssertEqual(mb.free, 0)
    }

    func testNormalizedBreakdownRawAppBeyondTotal() {
        // Degenerate input must never produce a bucket larger than RAM.
        let mb = SystemMetrics.normalizedBreakdown(
            total: 100, rawApp: 500, rawWired: 1, rawCompressed: 1, rawCached: 1)
        XCTAssertEqual(mb.app, 100)
        XCTAssertEqual(mb.wired, 0)
        XCTAssertEqual(mb.compressed, 0)
        XCTAssertEqual(mb.cached, 0)
        XCTAssertEqual(mb.free, 0)
    }

    func testNormalizedBreakdownZeroTotal() {
        let mb = SystemMetrics.normalizedBreakdown(
            total: 0, rawApp: 10, rawWired: 10, rawCompressed: 10, rawCached: 10)
        XCTAssertEqual(mb.total, 0)
        XCTAssertEqual(mb.app + mb.wired + mb.compressed + mb.cached + mb.free, 0)
        XCTAssertEqual(mb.pressure, 0)
    }

    // MARK: - ReleaseResult

    func testReleaseResultDelta() {
        let r = ReleaseResult(beforeBytes: 800, afterBytes: 600, outcome: .success)
        XCTAssertEqual(r.bytesReleased, 200)
        XCTAssertEqual(r.delta(total: 1000), 20.0, accuracy: 0.0001)
        XCTAssertTrue(r.success)
        XCTAssertFalse(r.cancelled)
        XCTAssertNil(r.errorMessage)
    }

    func testReleaseResultClampsWhenUsageGrewDuringPurge() {
        let r = ReleaseResult(beforeBytes: 500, afterBytes: 600, outcome: .success)
        XCTAssertEqual(r.bytesReleased, 0)
        XCTAssertEqual(r.delta(total: 1000), 0)
    }

    func testReleaseResultZeroTotal() {
        let r = ReleaseResult(beforeBytes: 800, afterBytes: 600, outcome: .success)
        XCTAssertEqual(r.delta(total: 0), 0)
    }

    func testReleaseResultCancelled() {
        let r = ReleaseResult(beforeBytes: 800, afterBytes: 600, outcome: .cancelled)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.errorMessage, "cancelled")
    }

    func testReleaseResultFailure() {
        let r = ReleaseResult(
            beforeBytes: 800, afterBytes: 600,
            outcome: .failure("sudo: a password is required"))
        XCTAssertFalse(r.success)
        XCTAssertFalse(r.cancelled)
        XCTAssertEqual(r.errorMessage, "sudo: a password is required")
    }

    // MARK: - MetricsSnapshot

    private func makeSnapshot(diskUsed: UInt64, diskTotal: UInt64) -> MetricsSnapshot {
        let mb = MemoryBreakdown(total: 100, app: 10, wired: 10, compressed: 10, cached: 10, free: 60)
        return MetricsSnapshot(cpu: 12.5, memory: mb.pressure, memBreakdown: mb,
                               gpuUsage: -1, diskUsed: diskUsed, diskTotal: diskTotal)
    }

    func testDiskPercent() {
        XCTAssertEqual(makeSnapshot(diskUsed: 250, diskTotal: 1000).diskPercent, 25.0, accuracy: 0.0001)
        XCTAssertEqual(makeSnapshot(diskUsed: 250, diskTotal: 0).diskPercent, 0)
    }

    func testSnapshotEncodesKeysTheJSExpects() throws {
        let data = try JSONEncoder().encode(makeSnapshot(diskUsed: 250, diskTotal: 1000))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["cpu", "memory", "memBreakdown", "gpuUsage", "diskUsed", "diskTotal", "diskPercent"] {
            XCTAssertNotNil(json[key], "missing key \(key)")
        }
        let breakdown = try XCTUnwrap(json["memBreakdown"] as? [String: Any])
        for key in ["total", "app", "wired", "compressed", "cached", "free"] {
            XCTAssertNotNil(breakdown[key], "missing memBreakdown key \(key)")
        }
    }

    // MARK: - UpdateChecker version comparison

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("1.4.0",  than: "1.3.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0",    than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.3.1",  than: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.0", than: "1.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.9", than: "1.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3",   than: "1.3.0"))
    }
}

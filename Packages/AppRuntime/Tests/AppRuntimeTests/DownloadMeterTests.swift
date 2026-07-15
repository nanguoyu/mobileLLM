// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

final class DownloadMeterTests: XCTestCase {

    /// A fresh meter with a known total shows "downloaded / total" but no speed/ETA yet.
    func testDetailShowsBytesBeforeSpeed() {
        var meter = DownloadMeter()
        meter.start(total: 4_600_000_000)
        meter.update(fraction: 0.5, now: Date(timeIntervalSince1970: 0))
        let detail = meter.detail
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail!.contains("/"), "detail should show downloaded / total: \(detail!)")
        XCTAssertFalse(detail!.contains("/s"), "no throughput before a second sample")
        XCTAssertFalse(detail!.contains("left"), "no ETA before a throughput estimate")
    }

    /// A second sample ≥0.4 s later yields a throughput and an ETA in both `detail` and `compactDetail`.
    func testSpeedAndETAAppearAfterSecondSample() {
        var meter = DownloadMeter()
        meter.start(total: 1_000_000_000)
        let t0 = Date(timeIntervalSince1970: 0)
        meter.update(fraction: 0.10, now: t0)                       // seeds the sampler
        meter.update(fraction: 0.20, now: t0.addingTimeInterval(1)) // +100 MB in 1 s → ~100 MB/s

        XCTAssertGreaterThan(meter.bytesPerSecond, 1)
        XCTAssertNotNil(meter.etaSeconds)

        let detail = meter.detail
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail!.contains("/s"), "throughput expected: \(detail!)")
        XCTAssertTrue(detail!.contains("left"), "ETA expected: \(detail!)")

        // compactDetail omits the total (no " / ") but keeps speed + ETA.
        let compact = meter.compactDetail
        XCTAssertNotNil(compact)
        XCTAssertFalse(compact!.contains(" / "), "compactDetail drops the total: \(compact!)")
        XCTAssertTrue(compact!.contains("/s"))
        XCTAssertTrue(compact!.contains("left"))
    }

    /// Unknown total (0) → the meter reports nothing rather than a misleading bar.
    func testUnknownTotalShowsNothing() {
        var meter = DownloadMeter()
        meter.start(total: 0)
        meter.update(fraction: 0.5)
        XCTAssertNil(meter.detail)
        XCTAssertNil(meter.compactDetail)
    }

    /// No ETA once complete (nothing left to estimate).
    func testNoETAWhenComplete() {
        var meter = DownloadMeter()
        meter.start(total: 500_000_000)
        let t0 = Date(timeIntervalSince1970: 0)
        meter.update(fraction: 0.5, now: t0)
        meter.update(fraction: 1.0, now: t0.addingTimeInterval(1))
        XCTAssertNil(meter.etaSeconds)
    }
}

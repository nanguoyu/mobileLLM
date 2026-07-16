// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The `current_location` tool driven through a fake `LocationProviding`: a success formats coordinates
/// (with/without a locality), and each failure maps to an instructive string (never a throw).
final class LocationToolTests: XCTestCase {

    private func run(_ result: Result<LocationFix, LocationError>) async -> String {
        await CurrentLocationTool(provider: FakeLocationProvider(result: result)).execute(argumentsJSON: "{}")
    }

    func testSuccessFormatsWithLocality() async {
        let fix = LocationFix(latitude: 37.33182, longitude: -122.03118, accuracy: 65, locality: "Cupertino")
        let out = await run(.success(fix))
        XCTAssertTrue(out.contains("Cupertino"))
        XCTAssertTrue(out.contains("37.33182"))
        XCTAssertTrue(out.contains("-122.03118"))
        XCTAssertTrue(out.contains("±65m"), out)
    }

    func testSuccessWithoutLocality() async {
        let out = await run(.success(LocationFix(latitude: 1, longitude: 2, accuracy: 10)))
        XCTAssertTrue(out.contains("1.00000, 2.00000"))
        XCTAssertFalse(out.contains("—"), "no place-name separator when locality is absent, got: \(out)")
    }

    func testDeniedMessage() async {
        let out = await run(.failure(.denied))
        XCTAssertTrue(out.contains("Location access is off"), out)
    }

    func testTimeoutMessage() async {
        let out = await run(.failure(.timeout))
        XCTAssertTrue(out.contains("try again"), out)
    }

    func testUnavailableMessage() async {
        let out = await run(.failure(.unavailable("no signal")))
        XCTAssertTrue(out.contains("unavailable"), out)
    }
}

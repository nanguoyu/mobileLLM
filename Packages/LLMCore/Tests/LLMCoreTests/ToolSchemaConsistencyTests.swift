// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// Guards the premise behind Tool V2 descriptor digests: the static schemas the app's frozen catalog
/// advertises must be byte-identical to the instance schemas the executor adapters build their
/// descriptors from. A divergence would make every plan fail `preparedPlanMismatch`.
final class ToolSchemaConsistencyTests: XCTestCase {
    func testStaticSchemasMatchInstanceSchemas() {
        XCTAssertEqual(WikipediaTool.schema, WikipediaTool().schema)
        XCTAssertEqual(WebScraperTool.schema, WebScraperTool().schema)
        XCTAssertEqual(RememberTool.schema, RememberTool(store: FakeMemoryStore()).schema)
        XCTAssertEqual(RecallTool.schema, RecallTool(store: FakeMemoryStore()).schema)
        XCTAssertEqual(
            CreateCalendarEventTool.schema,
            CreateCalendarEventTool(store: FakeEventStore()).schema
        )
        XCTAssertEqual(
            ListCalendarEventsTool.schema,
            ListCalendarEventsTool(store: FakeEventStore()).schema
        )
        XCTAssertEqual(
            CreateReminderTool.schema,
            CreateReminderTool(store: FakeEventStore()).schema
        )
        XCTAssertEqual(
            CurrentLocationTool.schema,
            CurrentLocationTool(provider: FakeLocationProvider(
                result: .success(LocationFix(latitude: 1, longitude: 2, accuracy: 3))
            )).schema
        )
    }
}

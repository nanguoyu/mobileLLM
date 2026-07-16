// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The gallery mapper against a REAL captured feed (`live-feed-fixture.xml`, saved from the live Skills
/// board). The synthetic fixtures in `SkillGalleryTests` are hand-shaped and agreed with the parser's
/// assumptions; this one doesn't — it's the actual bytes GitHub serves, and it's how the duplicate-rows
/// bug was caught: every entry's id parsed to 0 (GitHub's `<id>` is `tag:github.com,2008:<internal-id>`,
/// not a path ending in the discussion number), so `ForEach` saw five identical ids and rendered the first
/// row five times. Refresh the fixture with:
///   curl -sA mobileLLM-SkillGallery \
///     https://github.com/nanguoyu/mobileLLM/discussions/categories/skills.atom -o live-feed-fixture.xml
final class SkillGalleryLiveFeedTests: XCTestCase {

    private func liveFeed() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(component: "live-feed-fixture.xml")
        return try Data(contentsOf: url)
    }

    /// THE regression: distinct identities. A collision here is invisible to every other assertion but
    /// silently collapses the list in the UI.
    func testEveryItemHasADistinctNonZeroIdentity() throws {
        let items = try SkillGallery.items(fromFeed: liveFeed())
        XCTAssertGreaterThanOrEqual(items.count, 5)
        XCTAssertFalse(items.contains { $0.number == 0 }, "an unparsed id would collide with every other")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ForEach identity must be unique per row")
    }

    /// The real feed's rendered-HTML bodies must each yield their OWN skill — the shape that matters for
    /// the gallery being usable at all.
    func testEverySeededSkillParsesFromTheRealFeed() throws {
        let items = try SkillGallery.items(fromFeed: liveFeed())
        let names = Set(items.compactMap { $0.parsed?.name })
        for expected in ["Daily Briefing", "Meeting Notes", "Quick Reply", "Nearby & Now", "Expense Logger"] {
            XCTAssertTrue(names.contains(expected), "\(expected) should parse out of the live feed")
        }
        XCTAssertEqual(Set(items.map(\.title)).count, items.count, "titles are distinct per row")
    }

    /// Author + permalink survive the real feed (the row's byline and its Open-on-GitHub destination).
    func testAuthorAndPermalinkCarry() throws {
        let items = try SkillGallery.items(fromFeed: liveFeed())
        let first = try XCTUnwrap(items.first)
        XCTAssertFalse(first.author.isEmpty)
        XCTAssertNotEqual(first.author, "unknown")
        XCTAssertTrue(first.url.absoluteString.contains("/discussions/"), "row links to its own post")
    }
}

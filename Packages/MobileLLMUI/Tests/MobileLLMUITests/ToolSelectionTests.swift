// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
import LLMCore

/// Contracts behind the chat's tool picker: every engine-facing built-in has exactly one visible switch,
/// and the master authorization never rewrites the user's persisted selection.
@MainActor
final class ToolSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ToolSelectionTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEveryBuiltInToolHasExactlyOneVisibleSwitch() {
        let visible = BuiltInToolRow.all.flatMap(\.toolIDs)
        XCTAssertEqual(Set(visible), Set(ToolID.allCases), "no engine-facing tool may be missing from the picker")
        XCTAssertEqual(visible.count, Set(visible).count, "one ToolID must not be controlled by two switches")
    }

    func testMasterAuthorizationDoesNotRewriteTheSelection() {
        let settings = AppSettings(defaults: defaults)
        settings.disabledBuiltInTools = [
            ToolID.webSearch.rawValue,
            ToolID.wikipedia.rawValue,
            ToolID.currentLocation.rawValue,
        ]
        let selection = settings.disabledBuiltInTools

        settings.toolsEnabled = true
        settings.toolsEnabled = false

        XCTAssertEqual(settings.disabledBuiltInTools, selection)
        XCTAssertEqual(AppSettings(defaults: defaults).disabledBuiltInTools, selection,
                       "the same selected set survives a relaunch while master access is off")
    }

    func testSummaryDistinguishesSelectedToolsFromMasterAccess() {
        let settings = AppSettings(defaults: defaults)
        settings.disabledBuiltInTools = Set(ToolID.allCases.map(\.rawValue))

        XCTAssertEqual(ToolsView.summary(for: settings), "Off · 0 of 9 built-in tools selected")
        settings.toolsEnabled = true
        XCTAssertEqual(ToolsView.summary(for: settings), "0 of 9 built-in tools selected")
    }
}

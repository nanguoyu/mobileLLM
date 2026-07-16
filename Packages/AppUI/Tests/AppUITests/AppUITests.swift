// SPDX-License-Identifier: MIT

import XCTest
import SwiftUI
@testable import AppUI

/// AppUI is a view/token library, so these tests lock the numeric scale tokens (the part that can
/// silently drift and misalign every screen) and give the controls compile coverage.
final class AppUITests: XCTestCase {

    func testRadiusScale() {
        XCTAssertEqual(Theme.Radius.card, 16)
        XCTAssertEqual(Theme.Radius.canvas, 20)
        XCTAssertEqual(Theme.Radius.field, 12)
        XCTAssertEqual(Theme.Radius.control, 10)
        XCTAssertEqual(Theme.corner, Theme.Radius.card)   // kept in lockstep for source compat
    }

    func testSpaceScale() {
        XCTAssertEqual(Theme.Space.xs, 6)
        XCTAssertEqual(Theme.Space.sm, 10)
        XCTAssertEqual(Theme.Space.md, 12)
        XCTAssertEqual(Theme.Space.lg, 16)
        XCTAssertEqual(Theme.Space.xl, 20)
        XCTAssertEqual(Theme.Space.xxl, 28)
    }

    func testLayoutWidthTokens() {
        // Reading + form measures — lock them so views adopting the tokens can't silently drift.
        XCTAssertEqual(Theme.Layout.readingColumn, 700)
        XCTAssertEqual(Theme.Layout.form, 640)
    }

    func testControlsConstruct() {
        // Compile-coverage: the ported controls exist with their public initializers.
        _ = Chip(text: "1-bit")
        _ = Chip(text: "Ternary", filled: true)
        _ = Chip(text: "Q4_K_M", filled: false, size: .small)
        _ = StudioButtonStyle(.primary)
        _ = StudioButtonStyle(.secondary)
        _ = DotLabelStyle()
        _ = Segmented(selection: .constant(0), options: [0, 1], label: { "\($0)" })
    }
}

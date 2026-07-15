// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import AppRuntime

final class DeviceTierTests: XCTestCase {

    /// iPhone budget = half the physical RAM (jetsam-conservative).
    func testPhoneBudgetIsHalfRAM() {
        let phone = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)
        XCTAssertEqual(phone.memoryBudgetBytes, 4_000_000_000)
    }

    /// Mac budget = max(RAM − 4 GB, 0.80·RAM). At 16 GB the 0.80 term wins (12.8 GB).
    func testMacBudgetLeavesHeadroom() {
        let mac16 = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)
        XCTAssertEqual(mac16.memoryBudgetBytes, 12_800_000_000)   // 0.80 · 16e9

        // At 32 GB the (RAM − 4 GB) term wins (28 GB > 25.6 GB).
        let mac32 = DeviceTier(physicalMemoryBytes: 32_000_000_000, isPhone: false)
        XCTAssertEqual(mac32.memoryBudgetBytes, 28_000_000_000)
    }
}

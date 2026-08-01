// SPDX-License-Identifier: MIT

import XCTest
@testable import AgentContracts

final class CompilationSmokeTests: XCTestCase {
    func testContractModuleLoads() {
        XCTAssertEqual(AgentContractVersion.currentProtocol.description, "1.0.0")
    }
}

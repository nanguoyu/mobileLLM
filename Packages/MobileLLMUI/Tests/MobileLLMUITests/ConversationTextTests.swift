// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

final class ConversationTextTests: XCTestCase {
    func testPreviewsRemoveFormattingWithoutDroppingLinkLabelsOrUnicode() {
        XCTAssertEqual(ConversationText.preview("## Findings\n**Café** and [来源](https://example.com).\n- `SQLite`"), "Findings Café and 来源. SQLite")
        XCTAssertEqual(ConversationText.title("Plan an offline recipe app. Delegate separate investigations."), "Plan an offline recipe app")
        XCTAssertEqual(ConversationText.title("Compare Qwen3.5 and Qwen3.6 on my phone."), "Compare Qwen3.5 and Qwen3.6 on my phone")
    }
}

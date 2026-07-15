// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The Explore grouping heuristic (repo name → model identity + quant variants). Pure, so no network.
/// Inputs are real mlx-community repo leaf names.
final class RemoteCatalogTests: XCTestCase {

    private func repos(_ names: [String], dl: Int = 100) -> [(repo: String, dl: Int)] {
        names.map { (repo: "mlx-community/\($0)", dl: dl) }
    }

    func testSplitQuantPeelsTrailingDescriptors() {
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-8B-4bit").base, "Qwen3-8B")
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-8B-4bit").quant, "4-bit")
        XCTAssertEqual(RemoteCatalog.splitQuant("gpt-oss-20b-MXFP4-Q8").base, "gpt-oss-20b")
        XCTAssertEqual(RemoteCatalog.splitQuant("gemma-4-12B-it-OptiQ-4bit").base, "gemma-4-12B-it")
        XCTAssertEqual(RemoteCatalog.splitQuant("Llama-3.2-3B-Instruct-4bit").base, "Llama-3.2-3B-Instruct")
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-Embedding-0.6B-4bit-DWQ").base, "Qwen3-Embedding-0.6B")
        // No quant suffix → the whole leaf is the base.
        XCTAssertEqual(RemoteCatalog.splitQuant("Kimi-K2.5").base, "Kimi-K2.5")
        XCTAssertEqual(RemoteCatalog.splitQuant("Kimi-K2.5").quant, "default")
    }

    func testGroupsQuantsOfTheSameBase() {
        let g = RemoteCatalog.group(repos(["Qwen3-0.6B-8bit", "Qwen3-0.6B-4bit", "Qwen3-8B-4bit"]),
                                    publisher: "mlx-community", engine: .mlx)
        // Two distinct models; the 0.6B has two quants grouped.
        XCTAssertEqual(g.count, 2)
        let small = g.first { $0.name.contains("0.6B") }!
        XCTAssertEqual(small.variants.count, 2)
        // Sorted low-precision first → 4-bit before 8-bit.
        XCTAssertEqual(small.variants.map(\.quantLabel), ["4-bit", "8-bit"])
        XCTAssertEqual(small.engine, .mlx)
    }

    func testFiltersNonChatArtifacts() {
        let g = RemoteCatalog.group(repos(["Qwen3-Embedding-0.6B-4bit", "Qwen3-8B-4bit", "whisper-large-v3"]),
                                    publisher: "mlx-community", engine: .mlx)
        XCTAssertFalse(g.contains { $0.name.lowercased().contains("embedding") })
        XCTAssertFalse(g.contains { $0.name.lowercased().contains("whisper") })
        XCTAssertTrue(g.contains { $0.name.contains("Qwen3 8B") })
    }

    func testPreservesDownloadOrder() {
        let input = [("mlx-community/A-4bit", 500), ("mlx-community/B-4bit", 300), ("mlx-community/C-4bit", 100)]
            .map { (repo: $0.0, dl: $0.1) }
        let g = RemoteCatalog.group(input, publisher: "mlx-community", engine: .mlx)
        XCTAssertEqual(g.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(g.first?.downloads, 500)
    }

    func testPrettifyDropsInstructNoise() {
        XCTAssertEqual(RemoteCatalog.prettify("Llama-3.2-3B-Instruct"), "Llama 3.2 3B")
        XCTAssertEqual(RemoteCatalog.prettify("gemma-4-12B-it"), "gemma 4 12B")
    }

    func testQuantTokenRecognition() {
        for t in ["4bit", "8bit", "bf16", "mxfp4", "Q8", "q4_k_m", "DWQ", "OptiQ"] {
            XCTAssertTrue(RemoteCatalog.isQuantToken(t), "\(t) should be a quant token")
        }
        for t in ["Qwen3", "8B", "0.6B", "Instruct", "Coder"] {
            XCTAssertFalse(RemoteCatalog.isQuantToken(t), "\(t) should NOT be a quant token")
        }
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// SKILL.md interop — parsing the AI Edge Gallery community format, exporting ours back to it, the
/// run_js/secret capability detection, and URL normalization. The parse fixture mirrors a real published
/// community skill's structure (web-search via Serper), so drift from the ecosystem shows up here.
final class SkillIOTests: XCTestCase {

    private let gallerySkill = """
    ---
    name: web-search
    description: Search the internet for real-time information like latest news, weather, scores.
    metadata:
      require-secret: true
      require-secret-description: "Enter your Serper API key. Get free key at serper.dev"
    ---

    ## Examples
    - "Search for latest news"

    ## Instructions
    Use the `run_js` tool with `index.html` and provide JSON data containing a "query" field.

    ## Constraints
    Keep the query short: 2-5 English keywords only.
    """

    func testParsesTheGalleryFormat() throws {
        let p = try XCTUnwrap(SkillIO.parse(markdown: gallerySkill))
        XCTAssertEqual(p.name, "web-search")
        XCTAssertTrue(p.summary.hasPrefix("Search the internet"))
        XCTAssertTrue(p.instructions.contains("## Instructions"))
        XCTAssertTrue(p.instructions.contains("## Constraints"))
        XCTAssertFalse(p.instructions.contains("---"), "frontmatter must not leak into the instructions")
        XCTAssertTrue(p.requiresSecret)
        XCTAssertEqual(p.secretNote, "Enter your Serper API key. Get free key at serper.dev")
        XCTAssertTrue(p.requiresJSRuntime, "run_js/index.html references must be detected")
    }

    func testTextOnlySkillHasNoCapabilityFlags() throws {
        let md = """
        ---
        name: haiku-mode
        description: Answer everything as a haiku.
        ---
        Respond to every message as a single haiku. No explanations.
        """
        let p = try XCTUnwrap(SkillIO.parse(markdown: md))
        XCTAssertFalse(p.requiresSecret)
        XCTAssertFalse(p.requiresJSRuntime)
        XCTAssertEqual(p.instructions, "Respond to every message as a single haiku. No explanations.")
    }

    func testRejectsMissingFrontmatterOrName() {
        XCTAssertNil(SkillIO.parse(markdown: "just some text"))
        XCTAssertNil(SkillIO.parse(markdown: "---\ndescription: no name\n---\nbody"))
        XCTAssertNil(SkillIO.parse(markdown: "---\nname: empty-body\n---\n"))
    }

    /// Export → parse must round-trip our fields (the Gallery ignores our extra emoji metadata key,
    /// exactly as we ignore keys we don't know).
    func testExportRoundTripsThroughParse() throws {
        let skill = Skill(name: "Concise Mode", emoji: "✂️",
                          summary: "Trim every answer to the bone.",
                          instructions: "Answer in at most three sentences unless asked to expand.")
        let md = SkillIO.export(skill)
        let back = try XCTUnwrap(SkillIO.parse(markdown: md))
        XCTAssertEqual(back.name, skill.name)
        XCTAssertEqual(back.summary, skill.summary)
        XCTAssertEqual(back.instructions, skill.instructions)
        XCTAssertFalse(back.requiresSecret)
    }

    func testCandidateURLNormalization() {
        func first(_ raw: String) -> String? { SkillIO.candidateURLs(from: raw).first?.absoluteString }
        // A direct .md link passes through untouched.
        XCTAssertEqual(first("https://a.b/skill/SKILL.md"), "https://a.b/skill/SKILL.md")
        // A GitHub repo page maps to its raw SKILL.md on main.
        XCTAssertEqual(first("https://github.com/someone/web-search-skill"),
                       "https://raw.githubusercontent.com/someone/web-search-skill/main/SKILL.md")
        // A Pages webhost (the Gallery's documented layout) gets /SKILL.md appended, trailing slash or not.
        XCTAssertEqual(first("https://someone.github.io/web-search-skill/"),
                       "https://someone.github.io/web-search-skill/SKILL.md")
        // Scheme-less input is upgraded to https.
        XCTAssertEqual(first("someone.github.io/x"), "https://someone.github.io/x/SKILL.md")
        XCTAssertTrue(SkillIO.candidateURLs(from: "   ").isEmpty)
    }
}

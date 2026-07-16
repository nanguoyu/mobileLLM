// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The community Skill Gallery's fetch + mapping layer, driven entirely offline. The pure half — Atom feed
/// → `[GalleryItem]`, HTML-unescape, fenced-block extraction, title cleaning, install diffing — runs against
/// canned fixtures; the one impure method (`fetch(session:)`) runs end-to-end over a `URLProtocol` stub,
/// exactly like `SkillImportPipelineTests`. No test touches GitHub. The transport is the board's public
/// Atom feed — GitHub's GraphQL/REST-search APIs both require a token, so an anonymous app must read the feed.
final class SkillGalleryTests: XCTestCase {

    // MARK: - SKILL.md fixtures

    private static let dailyBriefingMD = """
    ---
    name: Daily Briefing
    description: A crisp morning rundown of weather, calendar, and top news.
    ---

    Give a concise morning briefing.
    - One line on the weather.
    - The day's top three priorities.
    - Keep it under 120 words.
    """

    private static let translatorMD = """
    ---
    name: Translator
    description: Translate between Chinese and English, translation only.
    ---

    Detect the input language and translate to the other. Output only the translation.
    """

    private static let anonymousTipsMD = """
    ---
    name: Anonymous Tips
    description: Small productivity nudges.
    ---

    Offer one short, practical productivity tip relevant to the user's message.
    """

    /// A SKILL.md whose own instructions contain a fenced code block — GitHub wraps such a field in a
    /// 4-backtick outer fence so the inner ``` doesn't close it. Exercises the length-aware extractor.
    private static let jsonHelperMD = """
    ---
    name: JSON Helper
    description: Explain and validate JSON payloads.
    metadata:
      emoji: 🧩
    ---

    Explain the JSON the user shares. When you show an example, wrap it like:
    ```
    { "ok": true }
    ```
    Then point out any schema issues.
    """

    // MARK: - Fixture assembly (mimics a GitHub Atom feed of discussion-form posts)

    /// A form-generated discussion body: a summary paragraph, then the SKILL.md rendered inside a fenced
    /// block (nil `skillMD` → a link-only post with no fence), then a trailing notes section — so the
    /// extractor has to skip the plain fields and stop at the right fence.
    private func body(summary: String, skillMD: String?, fence: String = "```") -> String {
        var lines = ["### One-line summary", "", summary, ""]
        if let md = skillMD {
            lines += ["### SKILL.md", "", "\(fence)markdown", md, fence, ""]
        } else {
            lines += ["### SKILL.md", "", "See https://example.com/skills/mine/SKILL.md for the file.", ""]
        }
        lines += ["### Notes (optional)", "", "Pairs well with web search."]
        return lines.joined(separator: "\n")
    }

    /// XML-escape a post body the way GitHub's Atom `<content>` carries it (entities the extractor must
    /// unescape before the fence reads correctly). `&` first so it doesn't double-encode the others.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `preEscaped:false` (the default) escapes the body the way GitHub's feed carries a form-field body
    /// (fenced markdown). `preEscaped:true` passes `body` through verbatim — for the rendered-HTML case,
    /// where the fixture already contains the entity-escaped `data-…` attribute exactly as the live feed does.
    private func entry(number: Int, title: String, body: String, author: String?, preEscaped: Bool = false) -> String {
        let authorBlock = author.map { "<author><name>\($0)</name></author>" } ?? "<author></author>"
        return """
        <entry>
          <id>tag:github.com,2008:/nanguoyu/mobileLLM/discussions/\(number)</id>
          <title>\(escape(title))</title>
          <link rel="alternate" type="text/html" href="https://github.com/nanguoyu/mobileLLM/discussions/\(number)"/>
          \(authorBlock)
          <content type="html">\(preEscaped ? body : escape(body))</content>
        </entry>
        """
    }

    private func feedData(_ entries: [String]) -> Data {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>tag:github.com,2008:/nanguoyu/mobileLLM/discussions/categories/skills</id>
          <title>Skills</title>
        \(entries.joined(separator: "\n"))
        </feed>
        """
        return Data(feed.utf8)
    }

    /// Five posts covering every mapping branch: a trailing-emoji title, a plain title, a nested-fence
    /// SKILL.md, a link-only (non-installable) post, and a null-author post — newest first, as the feed serves.
    private func sampleFeed() -> Data {
        feedData([
            entry(number: 5, title: "[Skill] Daily Briefing ☀️",
                  body: body(summary: "A crisp morning rundown.", skillMD: Self.dailyBriefingMD), author: "alice"),
            entry(number: 4, title: "[Skill] Translator",
                  body: body(summary: "Chinese ↔ English, translation only.", skillMD: Self.translatorMD), author: "bob"),
            entry(number: 3, title: "[Skill] JSON Helper 🧩",
                  body: body(summary: "Explain and validate JSON.", skillMD: Self.jsonHelperMD, fence: "````"), author: "dave"),
            entry(number: 2, title: "[Skill] My Web Toolkit",
                  body: body(summary: "A bundle of browser helpers.", skillMD: nil), author: "carol"),
            entry(number: 1, title: "[Skill] Anonymous Tips",
                  body: body(summary: "Tiny nudges.", skillMD: Self.anonymousTipsMD), author: nil),
        ])
    }

    // MARK: - Pure mapping: Atom feed → [GalleryItem]

    func testMapsAllEntriesInFeedOrder() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        XCTAssertEqual(items.map(\.number), [5, 4, 3, 2, 1], "the feed's order (newest first) is preserved")
    }

    func testTitleCleaningStripsTagAndTrailingEmoji() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        let daily = try XCTUnwrap(items.first { $0.number == 5 })
        XCTAssertEqual(daily.title, "Daily Briefing")
        XCTAssertEqual(daily.emoji, "☀️", "the trailing title emoji becomes the row glyph")

        let translator = try XCTUnwrap(items.first { $0.number == 4 })
        XCTAssertEqual(translator.title, "Translator")
        XCTAssertEqual(translator.emoji, "📦", "no title emoji → the neutral default glyph")
    }

    func testCleanTitleDirectly() {
        XCTAssertEqual(SkillGallery.cleanTitle("[Skill] Daily Briefing ☀️"), "Daily Briefing")
        XCTAssertEqual(SkillGallery.cleanTitle("[skill]  Translator"), "Translator", "case + inner spacing tolerated")
        XCTAssertEqual(SkillGallery.cleanTitle("Plain Title"), "Plain Title", "no tag → untouched")
        XCTAssertEqual(SkillGallery.cleanTitle("[Skill] Focus Mode 🎯✨"), "Focus Mode", "a whole trailing emoji run is peeled")
    }

    func testAuthorCarried() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        XCTAssertEqual(try XCTUnwrap(items.first { $0.number == 5 }).author, "alice")
        XCTAssertEqual(try XCTUnwrap(items.first { $0.number == 1 }).author, "unknown",
                       "a missing author falls back to 'unknown'")
    }

    func testInstallablePostParsesSkill() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        let daily = try XCTUnwrap(items.first { $0.number == 5 })
        XCTAssertTrue(daily.isInstallable)
        XCTAssertEqual(daily.parsed?.name, "Daily Briefing")
        XCTAssertEqual(daily.parsed?.summary, "A crisp morning rundown of weather, calendar, and top news.")
        XCTAssertTrue(daily.parsed?.instructions.contains("under 120 words") ?? false)
    }

    func testLinkOnlyPostListedButNotInstallable() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        let toolkit = try XCTUnwrap(items.first { $0.number == 2 }, "the link-only post is still listed")
        XCTAssertFalse(toolkit.isInstallable, "no ```markdown block → not installable in-app")
        XCTAssertNil(toolkit.parsed)
        XCTAssertNil(toolkit.rawMarkdown)
        XCTAssertEqual(toolkit.title, "My Web Toolkit", "still cleaned + shown so it can be opened on GitHub")
    }

    func testNestedFenceNotCutShort() throws {
        let items = try SkillGallery.items(fromFeed: sampleFeed())
        let json = try XCTUnwrap(items.first { $0.number == 3 })
        XCTAssertEqual(json.parsed?.name, "JSON Helper")
        // The 3-backtick sample inside the SKILL.md must survive the 4-backtick outer fence.
        XCTAssertTrue(json.parsed?.instructions.contains("{ \"ok\": true }") ?? false,
                      "the length-aware extractor keeps the inner code sample")
        XCTAssertTrue(json.rawMarkdown?.contains("```") ?? false)
    }

    // MARK: - HTML entity unescape (the Atom content is escaped markdown)

    func testUnescapeHTMLEntities() {
        XCTAssertEqual(SkillGallery.unescapeHTML("a &lt;b&gt; &amp; c &quot;d&quot;"), "a <b> & c \"d\"")
        XCTAssertEqual(SkillGallery.unescapeHTML("&#39;q&#39; &#x2764;"), "'q' ❤")
        XCTAssertEqual(SkillGallery.unescapeHTML("plain"), "plain")
    }

    // MARK: - GitHub's RENDERED-HTML clipboard block (the live-feed path)

    /// GitHub's Atom <content> is rendered HTML, NOT markdown: a ```markdown fence becomes a
    /// <div data-snippet-clipboard-copy-content="…raw source…">. This mirrors the real feed shape (verified
    /// against the live board) — the SKILL.md must come out of that attribute, entities and all.
    func testClipboardBlockExtractionFromRenderedHTML() throws {
        let content = """
        <p dir="auto">Log a spend in one line.</p>
        <h3 dir="auto">SKILL.md</h3>
        <div class="highlight highlight-text-md notranslate" dir="auto" data-snippet-clipboard-copy-content="---
        name: Expense Logger
        description: Turn a spend into a clean line — with a &lt;date&gt; and &quot;amount&quot;.
        ---
        Output one line: &lt;date&gt; · amount · category.">
        <pre>...rendered pretty version we ignore...</pre></div>
        """
        let raw = try XCTUnwrap(SkillGallery.clipboardBlock(in: content))
        XCTAssertTrue(raw.hasPrefix("---\nname: Expense Logger"))
        XCTAssertTrue(raw.contains("<date>"), "HTML entities in the copy attribute are unescaped")
        XCTAssertTrue(raw.contains("\"amount\""))
        let parsed = try XCTUnwrap(SkillIO.parse(markdown: raw))
        XCTAssertEqual(parsed.name, "Expense Logger")
    }

    func testClipboardBlockNilWhenNoBlockOrNotASkill() {
        XCTAssertNil(SkillGallery.clipboardBlock(in: "<p>just prose, no code block</p>"))
        // A code block that isn't a SKILL.md (no `name:`) is ignored, so an unrelated snippet in a post
        // doesn't get mistaken for the skill.
        XCTAssertNil(SkillGallery.clipboardBlock(in: #"<div data-snippet-clipboard-copy-content="print(42)">"#))
    }

    /// End-to-end over a feed whose entry carries the REAL rendered-HTML shape (clipboard attribute),
    /// proving the live path — not just the synthetic fenced fixtures — yields an installable item. The
    /// content is XML-escaped as GitHub's feed carries it (entities doubled: `&amp;` in the attribute
    /// becomes `&` after XMLParser, so a `&lt;` in the source is written `&amp;lt;` here).
    func testFeedWithRenderedHTMLBlockIsInstallable() throws {
        let content = """
        &lt;p&gt;Anything.&lt;/p&gt;&lt;div data-snippet-clipboard-copy-content="---
        name: Live Skill
        description: From a rendered GitHub block with a &amp;lt;placeholder&amp;gt;.
        ---
        Do the thing."&gt;&lt;pre&gt;ignored&lt;/pre&gt;&lt;/div&gt;
        """
        let feed = feedData([entry(number: 9, title: "[Skill] Live Skill 🛰️", body: content,
                                   author: "eve", preEscaped: true)])
        let items = try SkillGallery.items(fromFeed: feed)
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(item.isInstallable)
        XCTAssertEqual(item.parsed?.name, "Live Skill")
        XCTAssertEqual(item.emoji, "🛰️")
    }

    // MARK: - Fenced-block extraction (unit)

    func testExtractFirstMarkdownFence() {
        let body = "### SKILL.md\n\n```markdown\n---\nname: X\n---\n\nDo the thing.\n```\n\ntrailing prose"
        XCTAssertEqual(SkillGallery.extractSkillMarkdown(from: body), "---\nname: X\n---\n\nDo the thing.")
    }

    func testExtractAcceptsMdAlias() {
        XCTAssertEqual(SkillGallery.extractSkillMarkdown(from: "```md\nhello\n```"), "hello")
    }

    func testExtractReturnsNilWhenNoFence() {
        XCTAssertNil(SkillGallery.extractSkillMarkdown(from: "just prose, a link, no code block"))
    }

    // MARK: - Feed error paths

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try SkillGallery.items(fromFeed: Data("<<< not xml".utf8))) {
            XCTAssertEqual($0 as? SkillGallery.GalleryError, .malformedResponse)
        }
    }

    func testEmptyBoardYieldsNoItems() throws {
        XCTAssertEqual(try SkillGallery.items(fromFeed: feedData([])).count, 0)
    }

    // MARK: - Installed vs. available diffing

    @MainActor
    func testInstalledDiffingAgainstStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(component: "gallery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(fileURL: dir.appending(component: "skills.json"))
        await store.load()   // seed built-ins first (matches the launched app)

        let items = try SkillGallery.items(fromFeed: sampleFeed())
        let daily = try XCTUnwrap(items.first { $0.number == 5 })
        let toolkit = try XCTUnwrap(items.first { $0.number == 2 })

        XCTAssertFalse(daily.isInstalled(in: store), "available before it's created")
        // Create it under a case/space variant to prove detection is name-based and forgiving.
        store.create(name: "  daily briefing  ", emoji: "☀️", summary: "x", instructions: "y")
        XCTAssertTrue(daily.isInstalled(in: store), "same name (case/space-insensitive) reads as installed")

        XCTAssertFalse(toolkit.isInstalled(in: store), "a non-installable post is never 'installed'")
    }

    // MARK: - fetch() end-to-end via URLProtocol stub

    func testFetchParsesBoardEndToEnd() async throws {
        let session = stubbedSession()
        FeedStub.install(status: 200, body: sampleFeed())
        let items = try await SkillGallery.fetch(session: session)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.first?.title, "Daily Briefing")
        XCTAssertEqual(items.first?.parsed?.name, "Daily Briefing")
    }

    func testFetchRateLimitStatusThrows() async {
        let session = stubbedSession()
        FeedStub.install(status: 403, body: Data("rate limited".utf8))
        await assertThrows(.rateLimited) { try await SkillGallery.fetch(session: session) }
    }

    func testFetchUnauthorizedStatusThrows() async {
        let session = stubbedSession()
        FeedStub.install(status: 401, body: Data())
        await assertThrows(.unauthorized) { try await SkillGallery.fetch(session: session) }
    }

    func testFetchNetworkFailureThrows() async {
        let session = stubbedSession()
        FeedStub.installFailure(URLError(.cannotConnectToHost))
        do {
            _ = try await SkillGallery.fetch(session: session)
            XCTFail("expected a network error")
        } catch let error as SkillGallery.GalleryError {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Stub plumbing

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedStub.self]
        return URLSession(configuration: config)
    }

    private func assertThrows(_ expected: SkillGallery.GalleryError,
                              _ block: () async throws -> [SkillGallery.GalleryItem],
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await block()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SkillGallery.GalleryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

/// Answers the Atom-feed GET with a canned status + body (or a transport failure) so `SkillGallery.fetch`
/// runs fully offline. Mirrors `SkillImportPipelineTests`' stub.
final class FeedStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var status = 200
    private static var body = Data()
    private static var failure: URLError?

    static func install(status: Int, body: Data) {
        lock.lock(); self.status = status; self.body = body; self.failure = nil; lock.unlock()
    }
    static func installFailure(_ error: URLError) {
        lock.lock(); self.failure = error; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let status = Self.status, body = Self.body, failure = Self.failure
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

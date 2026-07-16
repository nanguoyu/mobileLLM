// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The page-reader tool: the SSRF host guard, the pure HTML→readable-text extraction (article-shaped /
/// nav-heavy / script-soup fixtures), truncation, and `execute` over a `URLProtocol` stub (content-type
/// guard, scheme/host rejection, graceful errors).
final class WebScraperToolTests: XCTestCase {

    // MARK: - SSRF host guard

    func testBlocksPrivateAndLoopbackHosts() {
        for host in ["localhost", "foo.localhost", "printer.local", "127.0.0.1", "10.0.0.5",
                     "192.168.1.1", "172.16.0.1", "172.31.255.255", "169.254.1.1", "::1", "0.0.0.0"] {
            XCTAssertTrue(WebScraperTool.isBlockedHost(host), "\(host) must be blocked")
        }
    }

    func testAllowsPublicHosts() {
        for host in ["example.com", "sub.example.org", "wikipedia.org", "8.8.8.8",
                     "172.15.0.1", "172.32.0.1", "11.0.0.1"] {
            XCTAssertFalse(WebScraperTool.isBlockedHost(host), "\(host) must be allowed")
        }
    }

    // MARK: - Readable-text extraction (pure)

    func testExtractsArticleAndDropsBoilerplate() {
        let text = WebScraperTool.collapse(WebScraperTool.extractReadableText(fromHTML: Fixtures.article))
        XCTAssertTrue(text.contains("Big Heading"))
        XCTAssertTrue(text.contains("First paragraph text."))
        XCTAssertTrue(text.contains("Second paragraph."))
        XCTAssertFalse(text.contains("Home About"), "nav must be dropped")
        XCTAssertFalse(text.contains("copyright"), "footer must be dropped")
        XCTAssertFalse(text.contains("var x"), "script must be dropped")
    }

    func testNavHeavyPageWithoutArticleStillExtractsContent() {
        let text = WebScraperTool.collapse(WebScraperTool.extractReadableText(fromHTML: Fixtures.navHeavy))
        XCTAssertTrue(text.contains("Real content here."))
        XCTAssertFalse(text.contains("Skip to main"), "nav links must be dropped")
        XCTAssertFalse(text.contains("all rights"), "footer must be dropped")
    }

    func testScriptSoupIsStrippedAndEntitiesDecoded() {
        let text = WebScraperTool.collapse(WebScraperTool.extractReadableText(fromHTML: Fixtures.scriptSoup))
        XCTAssertTrue(text.contains("Visible & clean."), "entity must decode, got: \(text)")
        XCTAssertFalse(text.contains("alert("))
        XCTAssertFalse(text.contains(".x{"))
    }

    func testParagraphBreaksSurvive() {
        let text = WebScraperTool.collapse(WebScraperTool.extractReadableText(fromHTML: Fixtures.article))
        // Heading and paragraphs should not be smashed onto one line.
        XCTAssertTrue(text.contains("\n"), "block structure should yield line breaks")
    }

    func testTruncationMarker() {
        let long = String(repeating: "a", count: 200)
        let out = WebScraperTool.truncate(long, to: 50)
        XCTAssertTrue(out.hasSuffix("[truncated]"))
        XCTAssertTrue(out.count < long.count)
        // Under the cap → untouched.
        XCTAssertEqual(WebScraperTool.truncate("short", to: 50), "short")
    }

    func testTitleExtraction() {
        XCTAssertEqual(WebScraperTool.title(ofHTML: Fixtures.article), "Doc Title")
        XCTAssertNil(WebScraperTool.title(ofHTML: "<html><body>no title</body></html>"))
    }

    // MARK: - execute() over a stubbed session

    private func tool(maxOutputChars: Int = 6000) -> WebScraperTool {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScraperMockProtocol.self]
        return WebScraperTool(session: URLSession(configuration: config), maxOutputChars: maxOutputChars)
    }

    private func run(_ url: String, maxOutputChars: Int = 6000) async -> String {
        await tool(maxOutputChars: maxOutputChars).execute(argumentsJSON: #"{"url":"\#(url)"}"#)
    }

    func testExecuteReturnsReadableTextWithTitle() async {
        let out = await run("https://example.com/article")
        XCTAssertTrue(out.contains("Doc Title"))
        XCTAssertTrue(out.contains("First paragraph text."))
        XCTAssertFalse(out.contains("<p>"), "no raw markup should leak")
    }

    func testExecuteRejectsNonHTMLContentType() async {
        let out = await run("https://example.com/json")
        XCTAssertTrue(out.contains("isn't a readable web page"), out)
    }

    func testExecuteRejectsNonHTTPScheme() async {
        let out = await run("ftp://example.com/file")
        XCTAssertTrue(out.contains("only http(s)"), out)
    }

    func testExecuteRejectsBlockedHost() async {
        let out = await run("http://localhost/secret")
        XCTAssertTrue(out.contains("isn't allowed"), out)
    }

    func testExecuteHandlesHTTPError() async {
        let out = await run("https://example.com/missing")
        XCTAssertTrue(out.hasPrefix("Error"), out)
    }

    func testExecuteMissingURL() async {
        let out = await tool().execute(argumentsJSON: "{}")
        XCTAssertTrue(out.contains("missing"))
    }

    func testExecuteTruncatesLongPage() async {
        let out = await run("https://example.com/article", maxOutputChars: 40)
        XCTAssertTrue(out.hasSuffix("[truncated]"), out)
    }
}

// MARK: - Canned page fixtures

private enum Fixtures {
    static let article = """
    <!DOCTYPE html><html><head><title>Doc Title</title><style>.x{color:red}</style></head>
    <body>
      <nav>Home About Contact</nav>
      <header>Site Header Banner</header>
      <article>
        <h1>Big Heading</h1>
        <p>First paragraph text.</p>
        <p>Second paragraph.</p>
      </article>
      <footer>copyright 2026</footer>
      <script>var x = 1; console.log(x);</script>
    </body></html>
    """

    static let navHeavy = """
    <html><body>
      <nav><a href="#">Skip to main</a><a href="#">Menu</a><a href="#">Login</a></nav>
      <div id="content"><div><p>Real content here.</p></div></div>
      <footer>© 2026 all rights reserved</footer>
    </body></html>
    """

    static let scriptSoup = """
    <html><body>
      <script>alert('boom')</script>
      <p>Visible &amp; clean.</p>
      <style>.x{display:none}</style>
      <noscript>enable js</noscript>
    </body></html>
    """
}

// MARK: - URLProtocol stub: routes by path, varies content type

private final class ScraperMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, type, body) = Self.response(for: request.url!)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func response(for url: URL) -> (Int, String, String) {
        switch url.path {
        case "/article": return (200, "text/html; charset=utf-8", Fixtures.article)
        case "/json":    return (200, "application/json", "{\"ok\":true}")
        case "/missing": return (404, "text/html", "not found")
        default:          return (404, "text/html", "")
        }
    }
}

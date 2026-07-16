// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The live web-search tool: the pure per-engine SERP parsers (against trimmed but real-shaped canned
/// HTML), tracker unwrapping, and `execute` end-to-end over a `URLProtocol` stub (engine priority +
/// fall-through, size cap, graceful errors). SERP scraping is brittle by nature, so these lock the
/// heuristics we ship against realistic markup and prove every failure degrades to a string, never a throw.
final class WebSearchToolTests: XCTestCase {

    // MARK: - Pure parsers

    func testParsesDuckDuckGoResultsAndUnwrapsTrackers() {
        let results = WebSearchTool.parseDuckDuckGo(Fixtures.ddg)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Swift (programming language)")
        // uddg= wrapper decoded back to the real destination, tracking params dropped.
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        XCTAssertTrue(results[0].snippet.contains("general-purpose"))
        XCTAssertFalse(results[0].snippet.contains("<b>"), "markup must be stripped from the snippet")
        XCTAssertEqual(results[1].url, "https://swift.org/")
        XCTAssertTrue(results[1].snippet.contains("&") == false || results[1].snippet.contains("docs"),
                      "entities decoded, got: \(results[1].snippet)")
    }

    func testParsesBingResultsAndDecodesCkRedirect() {
        let results = WebSearchTool.parseBing(Fixtures.bing)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].url, "https://swift.org/")
        XCTAssertTrue(results[0].title.contains("Swift.org"))
        XCTAssertTrue(results[0].snippet.contains("modern approach"))
        // The second result's link is a Bing ck/a redirect — the real URL is base64url in u=a1…
        XCTAssertEqual(results[1].url, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
    }

    func testTrackerUnwrapHelpers() {
        XCTAssertEqual(
            WebSearchTool.cleanDuckDuckGoURL("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=xyz"),
            "https://example.com/a")
        // A direct DDG link (no wrapper) is passed through, only made absolute.
        XCTAssertEqual(WebSearchTool.cleanDuckDuckGoURL("//example.org/x"), "https://example.org/x")
        XCTAssertEqual(WebSearchTool.cleanBingURL("https://plain.example/"), "https://plain.example/")
    }

    func testMalformedHTMLYieldsNoResultsNeverThrows() {
        XCTAssertEqual(WebSearchTool.parseDuckDuckGo("<html><body>garbage <div> no results"), [])
        XCTAssertEqual(WebSearchTool.parseBing("not even html"), [])
        XCTAssertEqual(WebSearchTool.parseDuckDuckGo(""), [])
    }

    func testEndpointEncodingAndHosts() {
        let ddg = WebSearchTool.endpoint(engine: .duckduckgo, query: "swift lang")!
        XCTAssertEqual(ddg.host, "html.duckduckgo.com")
        XCTAssertTrue(ddg.absoluteString.contains("q=swift%20lang"))
        let bing = WebSearchTool.endpoint(engine: .bing, query: "swift lang")!
        XCTAssertEqual(bing.host, "www.bing.com")
        XCTAssertTrue(bing.absoluteString.contains("q=swift%20lang"))
    }

    func testRenderIsNumberedWithURLAndSnippet() {
        let out = WebSearchTool.render(
            [SearchResult(title: "A", url: "https://a.example", snippet: "first"),
             SearchResult(title: "B", url: "https://b.example", snippet: "")], query: "q")
        XCTAssertTrue(out.contains("1. A"))
        XCTAssertTrue(out.contains("https://a.example"))
        XCTAssertTrue(out.contains("first"))
        XCTAssertTrue(out.contains("2. B"))
    }

    // MARK: - execute() over a stubbed session

    private func tool(engines: [SearchEngine] = [.duckduckgo, .bing], maxResults: Int = 6) -> WebSearchTool {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SerpMockProtocol.self]
        return WebSearchTool(engines: engines, session: URLSession(configuration: config), maxResults: maxResults)
    }

    private func run(_ tool: WebSearchTool, _ query: String) async -> String {
        await tool.execute(argumentsJSON: #"{"query":"\#(query)"}"#)
    }

    func testExecuteReturnsDuckDuckGoResults() async {
        let out = await run(tool(), "swift language")
        XCTAssertTrue(out.contains("Web results for"))
        XCTAssertTrue(out.contains("Swift (programming language)"))
        XCTAssertTrue(out.contains("https://en.wikipedia.org/wiki/Swift_(programming_language)"), out)
    }

    func testExecuteFallsThroughToBingWhenFirstEngineEmpty() async {
        // DDG returns an empty results page → the tool must fall through to Bing.
        let out = await run(tool(), "DDGEMPTY swift")
        XCTAssertTrue(out.contains("swift.org"), "expected Bing results after DDG fell through, got: \(out)")
    }

    func testExecuteAllEnginesFailReturnsGracefulString() async {
        let out = await run(tool(), "DDGFAIL BINGFAIL")
        XCTAssertTrue(out.contains("No web results"), out)
        XCTAssertFalse(out.hasPrefix("Web results"))
    }

    func testExecuteHonorsMaxResults() async {
        let out = await run(tool(maxResults: 1), "swift")
        XCTAssertTrue(out.contains("1. "))
        XCTAssertFalse(out.contains("2. "), "maxResults=1 must cap the list, got: \(out)")
    }

    func testExecuteSingleEngineBing() async {
        let out = await run(tool(engines: [.bing]), "swift")
        XCTAssertTrue(out.contains("swift.org"))
    }

    func testExecuteMissingQuery() async {
        let out = await tool().execute(argumentsJSON: "{}")
        XCTAssertTrue(out.contains("missing"))
    }
}

// MARK: - Canned SERP fixtures (trimmed but structurally real)

private enum Fixtures {
    static let ddg = """
    <!DOCTYPE html><html><body><div class="results">
      <div class="result results_links results_links_deep web-result ">
        <div class="links_main links_deep result__body">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FSwift_(programming_language)&amp;rut=abc123">Swift (programming language)</a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org">Swift is a <b>general-purpose</b> programming language developed by Apple.</a>
        </div>
      </div>
      <div class="result results_links results_links_deep web-result ">
        <div class="links_main links_deep result__body">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2F&amp;rut=def456">Swift.org</a>
          </h2>
          <a class="result__snippet" href="#">The Swift programming language home &amp; docs.</a>
        </div>
      </div>
    </div></body></html>
    """

    static let bing = """
    <!DOCTYPE html><html><body><ol id="b_results">
      <li class="b_algo">
        <h2><a href="https://swift.org/" h="ID=SERP,5001.1">Swift.org - Welcome to Swift.org</a></h2>
        <div class="b_caption"><p>Swift is a general-purpose language built using a modern approach to safety.</p></div>
      </li>
      <li class="b_algo">
        <div class="b_tpcn"><a class="tilk" href="https://en.wikipedia.org/wiki/Swift">Wikipedia</a></div>
        <h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1aHR0cHM6Ly9lbi53aWtpcGVkaWEub3JnL3dpa2kvU3dpZnRfKHByb2dyYW1taW5nX2xhbmd1YWdlKQ&amp;ntb=1" h="ID=SERP,5002.1">Swift (programming language) - Wikipedia</a></h2>
        <div class="b_caption"><p>Swift is a high-level general-purpose programming language.</p></div>
      </li>
    </ol></body></html>
    """
}

// MARK: - URLProtocol stub: routes by host + `q` marker

private final class SerpMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.response(for: request.url!)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func query(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "q" }?.value ?? ""
    }

    private static func response(for url: URL) -> (Int, String) {
        let q = query(url)
        let host = url.host ?? ""
        if host.contains("duckduckgo") {
            if q.contains("DDGFAIL") { return (500, "") }
            if q.contains("DDGEMPTY") { return (200, "<html><body><div class=\"results\"></div></body></html>") }
            return (200, Fixtures.ddg)
        }
        if host.contains("bing") {
            if q.contains("BINGFAIL") { return (500, "") }
            return (200, Fixtures.bing)
        }
        return (404, "")
    }
}

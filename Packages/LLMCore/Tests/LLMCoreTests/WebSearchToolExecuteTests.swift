// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// `WebSearchTool.execute` driven end-to-end against CANNED Wikipedia responses (a `URLProtocol` stub on an
/// injected session). The pure helpers (`lang`, `parseTopTitle`, `parseSummary`) are already covered in
/// `ToolsTests`; these pin the network-facing behavior those can't: that a query actually ROUTES to the
/// right-language host, and that every failure path returns a graceful error STRING (execute never throws).
final class WebSearchToolExecuteTests: XCTestCase {

    private func tool() -> WebSearchTool {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WikiMockProtocol.self]
        return WebSearchTool(session: URLSession(configuration: config))
    }

    private func run(_ query: String) async -> String {
        await tool().execute(argumentsJSON: #"{"query":"\#(query)"}"#)
    }

    /// A Latin query routes to en.wikipedia.org and yields "Title: summary". The mock echoes the host it was
    /// hit on into the summary, so the result proves the request reached the ENGLISH host.
    func testEnglishQueryRoutesToEnglishHost() async {
        let result = await run("Alan Turing")
        XCTAssertTrue(result.contains("TestArticle"), "the article title is surfaced")
        XCTAssertTrue(result.contains("en.wikipedia.org"), "an en query must hit the English host, got: \(result)")
        XCTAssertFalse(result.contains("zh.wikipedia.org"))
    }

    /// A CJK query routes to zh.wikipedia.org.
    func testChineseQueryRoutesToChineseHost() async {
        let result = await run("北京在哪里")
        XCTAssertTrue(result.contains("zh.wikipedia.org"), "a zh query must hit the Chinese host, got: \(result)")
        XCTAssertFalse(result.contains("en.wikipedia.org"))
    }

    /// An empty search result set returns the "no article" string, not an error/throw.
    func testEmptyResultReturnsNoArticleString() async {
        let result = await run("EMPTYQUERY")
        XCTAssertTrue(result.contains("No Wikipedia article found"), "got: \(result)")
    }

    /// Malformed search JSON is swallowed into the same graceful "no article" string (parse → nil), never a throw.
    func testMalformedSearchJSONReturnsErrorString() async {
        let result = await run("BADJSONQUERY")
        XCTAssertTrue(result.contains("No Wikipedia article found"), "got: \(result)")
    }

    /// A found article whose SUMMARY endpoint returns malformed JSON degrades to the "no summary" string.
    func testMalformedSummaryJSONReturnsNoSummaryString() async {
        let result = await run("BADSUMMARYQUERY")
        XCTAssertTrue(result.contains("no summary"), "got: \(result)")
        XCTAssertTrue(result.contains("BadSummaryTitle"), "the found title is still named, got: \(result)")
    }

    /// A network/HTTP failure returns the "couldn't reach Wikipedia" string — execute catches and never throws.
    func testHTTPErrorReturnsReachabilityErrorString() async {
        let result = await run("SERVERERROR")
        XCTAssertTrue(result.contains("Search failed"), "got: \(result)")
    }

    /// Missing / blank query short-circuits with a clear error before any network call.
    func testMissingOrBlankQueryReturnsMissingError() async {
        let missing = await tool().execute(argumentsJSON: "{}")
        XCTAssertTrue(missing.contains("missing"), "got: \(missing)")
        let blank = await tool().execute(argumentsJSON: #"{"query":"   "}"#)
        XCTAssertTrue(blank.contains("missing"), "a whitespace-only query is treated as missing, got: \(blank)")
    }
}

// MARK: - Canned Wikipedia URLProtocol (stateless; a pure function of the request URL)

private final class WikiMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = response(for: request.url!)
        let headers = ["Content-Type": "application/json"]
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func queryItem(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == name }?.value
    }

    private func response(for url: URL) -> (Int, Data) {
        let path = url.path
        // Step 1: the MediaWiki search endpoint. `srsearch` carries the scenario marker.
        if path.contains("/w/api.php") {
            let srsearch = queryItem("srsearch", in: url) ?? ""
            if srsearch.contains("SERVERERROR") { return (500, Data("{}".utf8)) }
            if srsearch.contains("BADJSON") { return (200, Data("this is not valid json {".utf8)) }
            if srsearch.contains("EMPTYQUERY") { return (200, Data(#"{"query":{"search":[]}}"#.utf8)) }
            let title = srsearch.contains("BADSUMMARY") ? "BadSummaryTitle" : "TestArticle"
            return (200, Data(#"{"query":{"search":[{"title":"\#(title)","pageid":1}]}}"#.utf8))
        }
        // Step 2: the REST summary endpoint. Echo the HOST back so the caller can prove routing.
        if path.contains("/api/rest_v1/page/summary/") {
            let title = url.lastPathComponent
            if title == "BadSummaryTitle" { return (200, Data("definitely not json".utf8)) }
            let host = url.host ?? "?"
            return (200, Data(#"{"title":"\#(title)","extract":"Summary via \#(host)"}"#.utf8))
        }
        return (404, Data())
    }
}

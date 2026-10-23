// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class DeepSeekWebClientTests: XCTestCase {
    func testSearchCanReturnBoundedPageContentWithoutCallingFetchOrInventingFreshness() async throws {
        let original = String(repeating: "界😊", count: 1000) + " https://unread.example/linked-page"
        let spy = DeepSeekRequestProbe(content: original)
        let response = try await makeClient(spy).perform(operation: .search, argument: "primary group", apiKey: "test-key", includeSearchContent: true)
        let hit = try XCTUnwrap(response.searchResults?.first)
        XCTAssertFalse(hit.pageExcerpt.isEmpty)
        XCTAssertTrue(original.hasPrefix(hit.pageExcerpt))
        XCTAssertLessThanOrEqual(hit.pageExcerpt.utf8.count, 3000)
        XCTAssertTrue(hit.pageExcerptTruncated)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url!.path.hasSuffix("/search"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        XCTAssertEqual(body["need_content"] as? Bool, true)
        let summaryOnly = try await makeClient(spy).perform(operation: .search, argument: "primary group", apiKey: "test-key", includeSearchContent: false)
        XCTAssertEqual(summaryOnly.searchResults?.first?.pageExcerpt, "", "A summary-only request cannot be promoted to page content")
    }

    func testQueryLimitsCountUnicodeScalarsAndPreserveSearchOperators() throws {
        let query = "官方文档 site:api-docs.deepseek.com"
        let body = try DeepSeekWebClient.requestBody(operation: .search, argument: query)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["query"] as? String, query)
        XCTAssertEqual(json["count"] as? Int, 6)
        XCTAssertEqual(json["need_content"] as? Bool, false)
        XCTAssertNoThrow(try DeepSeekWebClient.requestBody(operation: .search, argument: String(repeating: "中", count: 128)))
        for query in ["   ", String(repeating: "中", count: 129)] {
            XCTAssertThrowsError(try DeepSeekWebClient.requestBody(operation: .search, argument: query))
        }
        for url in ["http://example.com", "https://user:pass@example.com/", "https://127.0.0.1/", "https://internal.local/"] {
            XCTAssertThrowsError(try DeepSeekWebClient.requestBody(operation: .fetch, argument: url))
        }
    }

    func testSearchAndFetchUseOfficialEndpointsAndReturnSourcesAndAccountedBytes() async throws {
        let spy = DeepSeekRequestProbe()
        let client = makeClient(spy)
        let search = try await client.perform(operation: .search, argument: "test query", apiKey: "test-key")
        XCTAssertTrue(search.text.contains("https://example.com/article"))
        XCTAssertTrue(search.text.contains("Long summary"))
        XCTAssertTrue(search.text.hasPrefix("Retrieval: SEARCH_SUMMARIES_ONLY"))
        XCTAssertTrue(search.text.contains("Source metadata date: 2025-09-04T00:00:00+00:00"))
        let page = try await client.perform(operation: .fetch, argument: "https://example.com/article", apiKey: "test-key")
        XCTAssertTrue(page.text.contains("# Article body"))
        XCTAssertTrue(page.text.hasPrefix("Retrieval: FETCHED_PAGE_EXCERPT"))
        XCTAssertGreaterThan(page.responseBytes, 0)
        let requests = await spy.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [
            "https://api.deepseek.com/v1/tools/search", "https://api.deepseek.com/v1/tools/fetch"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" })
        XCTAssertEqual(search.requestBytes, UInt64(requests[0].httpBody!.count))
        XCTAssertEqual(page.requestBytes, UInt64(requests[1].httpBody!.count))
    }

    func testRedirectNeverReceivesASecondAuthenticatedRequest() async throws {
        let spy = DeepSeekRequestProbe(status: 302)
        do {
            _ = try await makeClient(spy).perform(operation: .search, argument: "test", apiKey: "test-key")
            XCTFail("Even a same-origin redirect must be rejected")
        } catch let error as DeepSeekWebError { XCTAssertEqual(error, .httpStatus(302)) }
        let count = await spy.requests.count
        XCTAssertEqual(count, 1)
    }

    func testErrorsAndOversizedResponsesFailWithoutLeakingServerBody() async throws {
        for status in [401, 402, 429, 500] {
            let probe = DeepSeekRequestProbe(status: status)
            do {
                _ = try await makeClient(probe).perform(operation: .search, argument: "test", apiKey: "test-key",
                    consumeResponseBytes: { await probe.account($0) })
                XCTFail("HTTP error must fail")
            } catch let error as DeepSeekWebError {
                XCTAssertEqual(error, .httpStatus(status))
                XCTAssertFalse(error.localizedDescription.contains("server-secret"))
            }
            let accounted = await probe.accountedBytes
            XCTAssertEqual(accounted, UInt64(Data("server-secret".utf8).count))
        }
        do {
            _ = try await makeClient(DeepSeekRequestProbe(truncated: true)).perform(operation: .search, argument: "test", apiKey: "test-key")
            XCTFail("Truncated JSON must not be accepted")
        } catch let error as DeepSeekWebError { XCTAssertEqual(error, .responseTooLarge) }
    }

    func testPrivatePageAndMissingCredentialsMakeNoRequest() async throws {
        let spy = DeepSeekRequestProbe()
        let client = makeClient(spy, addresses: ["10.0.0.1"])
        do {
            _ = try await client.perform(operation: .fetch, argument: "https://internal.example/page", apiKey: "test-key")
            XCTFail("Private DNS results must be rejected")
        } catch let error as WebNetworkError { XCTAssertEqual(error, .blockedHost) }
        do {
            _ = try await client.perform(operation: .search, argument: "test", apiKey: "")
            XCTFail("Missing key must fail before I/O")
        } catch let error as DeepSeekWebError { XCTAssertEqual(error, .missingAPIKey) }
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func makeClient(_ spy: DeepSeekRequestProbe, addresses: [String] = ["1.1.1.1"]) -> DeepSeekWebClient {
        DeepSeekWebClient(policy: WebURLPolicy(resolve: { _ in addresses }),
                         transport: WebHTTPTransport { request, limit in await spy.load(request, limit: limit) })
    }
}

private actor DeepSeekRequestProbe {
    var requests: [URLRequest] = []
    var accountedBytes: UInt64 = 0
    func account(_ bytes: UInt64) { accountedBytes += bytes }
    let status: Int
    let truncated: Bool
    let content: String?
    init(status: Int = 200, truncated: Bool = false, content: String? = nil) {
        self.status = status; self.truncated = truncated; self.content = content
    }
    func load(_ request: URLRequest, limit: Int) -> WebHTTPResponse {
        requests.append(request)
        let search = try! JSONSerialization.data(withJSONObject: ["results": [[
            "title": "Article", "url": "https://example.com/article", "snippet": "Short", "summary": "Long summary",
            "date": "2025-09-04T00:00:00+00:00", "content": content as Any? ?? NSNull(),
        ]]])
        let body = status != 200 ? Data("server-secret".utf8) : request.url!.path.hasSuffix("search")
            ? search : Data(##"{"title":"Article","content":"# Article body"}"##.utf8)
        return WebHTTPResponse(response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: status == 302 ? ["Location": "https://api.deepseek.com/redirect"] : [:])!,
            body: body, wasTruncated: truncated)
    }
}

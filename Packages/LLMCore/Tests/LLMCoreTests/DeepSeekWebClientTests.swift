// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class DeepSeekWebClientTests: XCTestCase {
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
        let page = try await client.perform(operation: .fetch, argument: "https://example.com/article", apiKey: "test-key")
        XCTAssertTrue(page.text.contains("# Article body"))
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
        } catch let error as WebNetworkError { XCTAssertEqual(error, .tooManyRedirects) }
        let count = await spy.requests.count
        XCTAssertEqual(count, 1)
    }

    func testErrorsAndOversizedResponsesFailWithoutLeakingServerBody() async throws {
        for status in [401, 402, 429, 500] {
            do {
                _ = try await makeClient(DeepSeekRequestProbe(status: status)).perform(operation: .search, argument: "test", apiKey: "test-key")
                XCTFail("HTTP error must fail")
            } catch let error as DeepSeekWebError {
                XCTAssertEqual(error, .httpStatus(status))
                XCTAssertFalse(error.localizedDescription.contains("server-secret"))
            }
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
    let status: Int
    let truncated: Bool
    init(status: Int = 200, truncated: Bool = false) { self.status = status; self.truncated = truncated }
    func load(_ request: URLRequest, limit: Int) -> WebHTTPResponse {
        requests.append(request)
        let body = status != 200 ? "server-secret" : request.url!.path.hasSuffix("search")
            ? #"{"results":[{"title":"Article","url":"https://example.com/article","snippet":"Short","summary":"Long summary"}]}"#
            : #"{"title":"Article","content":"# Article body"}"#
        return WebHTTPResponse(response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: status == 302 ? ["Location": "https://api.deepseek.com/redirect"] : [:])!,
            body: Data(body.utf8), wasTruncated: truncated)
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class WebHTTPClientTests: XCTestCase {

    func testPolicyRejectsPrivateOrReservedDNSAnswers() async {
        let blocked = [
            "127.0.0.1", "10.0.0.1", "100.64.0.1", "169.254.169.254",
            "192.0.2.1", "198.18.0.1", "203.0.113.1", "224.0.0.1",
            "::1", "fc00::1", "fe80::1", "2001::1", "2001:db8::1", "2002:0808:0808::1", "ff02::1",
            "::ffff:192.168.1.1", "64:ff9b::10.0.0.1",
        ]

        for address in blocked {
            let policy = WebURLPolicy(resolve: { _ in [address] })
            await assertValidationError(.blockedHost, policy: policy, url: "https://public.example/")
        }
    }

    func testPolicyAllowsPublicIPv4AndIPv6Answers() async throws {
        for address in ["1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"] {
            let policy = WebURLPolicy(resolve: { _ in [address] })
            try await policy.validate(URL(string: "https://public.example/")!)
        }
    }

    func testPolicyRejectsMixedPublicPrivateDNSAnswer() async {
        let policy = WebURLPolicy(resolve: { _ in ["93.184.216.34", "10.0.0.8"] })
        await assertValidationError(.blockedHost, policy: policy, url: "https://mixed.example/")
    }

    func testPolicyRejectsSchemesCredentialsAndLocalNamesBeforeDNS() async {
        let resolver = ResolverSpy(addresses: ["93.184.216.34"])
        let policy = WebURLPolicy(resolve: { host in try await resolver.resolve(host) })

        await assertValidationError(.unsupportedScheme, policy: policy, url: "file:///etc/passwd")
        await assertValidationError(.invalidURL, policy: policy, url: "https://user:pass@example.com/")
        await assertValidationError(.blockedHost, policy: policy, url: "http://metadata.local/")
        let calls = await resolver.calls
        XCTAssertEqual(calls, [], "obviously unsafe URLs must never reach DNS")
    }

    func testDNSFailureIsDistinctFromBlockedAddress() async {
        let policy = WebURLPolicy(resolve: { _ in throw StubError.failed })
        await assertValidationError(.dnsResolutionFailed, policy: policy, url: "https://missing.example/")
    }

    func testPrivateRedirectIsRejectedBeforeSecondRequest() async throws {
        let server = RedirectServer { request, _ in
            Self.response(
                url: request.url!,
                status: 302,
                headers: ["Location": "http://169.254.169.254/latest/meta-data/"]
            )
        }
        let client = WebHTTPClient(
            policy: WebURLPolicy(resolve: { _ in ["93.184.216.34"] }),
            transport: WebHTTPTransport { request, limit in
                try await server.load(request, maxBytes: limit)
            }
        )

        do {
            _ = try await client.get(URLRequest(url: URL(string: "https://public.example/start")!),
                                     maxBytes: 1024)
            XCTFail("private redirect should be rejected")
        } catch let error as WebNetworkError {
            XCTAssertEqual(error, .unsafeRedirect)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let requested = await server.requestedURLs
        XCTAssertEqual(requested.map(\.host), ["public.example"])
    }

    func testPublicRedirectIsRevalidatedAndFollowed() async throws {
        let resolver = ResolverSpy(addressesByHost: [
            "public.example": ["93.184.216.34"],
            "cdn.example": ["1.1.1.1"],
        ])
        let server = RedirectServer { request, _ in
            if request.url?.host == "public.example" {
                return Self.response(
                    url: request.url!,
                    status: 301,
                    headers: ["Location": "https://cdn.example/final"]
                )
            }
            return Self.response(url: request.url!, status: 200, body: Data("done".utf8))
        }
        let client = WebHTTPClient(
            policy: WebURLPolicy(resolve: { host in try await resolver.resolve(host) }),
            transport: WebHTTPTransport { request, limit in
                try await server.load(request, maxBytes: limit)
            }
        )

        let result = try await client.get(
            URLRequest(url: URL(string: "https://public.example/start")!),
            maxBytes: 1024
        )
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "done")
        let requested = await server.requestedURLs
        XCTAssertEqual(requested.map(\.absoluteString), [
            "https://public.example/start",
            "https://cdn.example/final",
        ])
        let resolved = await resolver.calls
        XCTAssertEqual(resolved, ["public.example", "cdn.example"])
    }

    func testRedirectLoopIsBounded() async {
        let server = RedirectServer { request, _ in
            Self.response(url: request.url!, status: 302, headers: ["Location": "/same"])
        }
        let client = WebHTTPClient(
            policy: WebURLPolicy(resolve: { _ in ["93.184.216.34"] }),
            transport: WebHTTPTransport { request, limit in
                try await server.load(request, maxBytes: limit)
            }
        )

        do {
            _ = try await client.get(URLRequest(url: URL(string: "https://public.example/same")!),
                                     maxBytes: 1024)
            XCTFail("redirect loop should fail")
        } catch let error as WebNetworkError {
            XCTAssertEqual(error, .tooManyRedirects)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testURLSessionTransportStopsAtByteLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LargeBodyProtocol.self]
        let session = URLSession(configuration: config)
        let client = WebHTTPClient(session: session, resolver: { _ in ["93.184.216.34"] })
        var request = URLRequest(url: URL(string: "https://public.example/large")!)
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let result = try await client.get(request, maxBytes: 128)

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.body.count, 128)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.body, Data(repeating: 0x61, count: 128))
    }

    func testURLSessionDelegateStopsAndRevalidatesActualRedirect() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: config)
        let client = WebHTTPClient(session: session, resolver: { _ in ["93.184.216.34"] })

        let result = try await client.get(
            URLRequest(url: URL(string: "https://public.example/public-redirect")!),
            maxBytes: 1024
        )

        XCTAssertEqual(result.response.url?.host, "cdn.example")
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "redirected")
    }

    func testURLSessionDelegateNeverFollowsPrivateRedirectAutomatically() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: config)
        let client = WebHTTPClient(session: session, resolver: { _ in ["93.184.216.34"] })

        do {
            _ = try await client.get(
                URLRequest(url: URL(string: "https://public.example/private-redirect")!),
                maxBytes: 1024
            )
            XCTFail("private redirect should fail")
        } catch let error as WebNetworkError {
            XCTAssertEqual(error, .unsafeRedirect)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func assertValidationError(_ expected: WebNetworkError,
                                       policy: WebURLPolicy,
                                       url: String) async {
        do {
            try await policy.validate(URL(string: url)!)
            XCTFail("expected \(expected) for \(url)")
        } catch let error as WebNetworkError {
            XCTAssertEqual(error, expected, url)
        } catch {
            XCTFail("unexpected error for \(url): \(error)")
        }
    }

    private static func response(url: URL,
                                 status: Int,
                                 headers: [String: String] = [:],
                                 body: Data = Data()) -> WebHTTPResponse {
        WebHTTPResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            body: body,
            wasTruncated: false
        )
    }
}

private enum StubError: Error {
    case failed
}

private actor ResolverSpy {
    private let defaultAddresses: [String]
    private let addressesByHost: [String: [String]]
    private(set) var calls: [String] = []

    init(addresses: [String]) {
        self.defaultAddresses = addresses
        self.addressesByHost = [:]
    }

    init(addressesByHost: [String: [String]]) {
        self.defaultAddresses = []
        self.addressesByHost = addressesByHost
    }

    func resolve(_ host: String) throws -> [String] {
        calls.append(host)
        return addressesByHost[host] ?? defaultAddresses
    }
}

private actor RedirectServer {
    typealias Handler = @Sendable (URLRequest, Int) throws -> WebHTTPResponse

    private let handler: Handler
    private(set) var requestedURLs: [URL] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func load(_ request: URLRequest, maxBytes: Int) throws -> WebHTTPResponse {
        requestedURLs.append(request.url!)
        return try handler(request, maxBytes)
    }
}

private final class LargeBodyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "4096",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0..<16 {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 256))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RedirectingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch request.url?.path {
        case "/public-redirect":
            redirect(to: URL(string: "https://cdn.example/final")!)
        case "/private-redirect":
            redirect(to: URL(string: "http://169.254.169.254/latest/meta-data/")!)
        case "/final":
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("redirected".utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }

    private func redirect(to url: URL) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": url.absoluteString]
        )!
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: url),
            redirectResponse: response
        )
    }
}

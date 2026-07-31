// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors shared by the live-web tools. They stay internal because tools turn them into short,
/// model-readable strings rather than exposing networking implementation details.
enum WebNetworkError: Error, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case blockedHost
    case dnsResolutionFailed
    case unsafeRedirect
    case invalidRedirect
    case tooManyRedirects
    case badResponse
}

typealias WebDNSResolver = @Sendable (_ host: String) async throws -> [String]

/// Validates every URL before it reaches URLSession. A hostname is allowed only when every address
/// returned by DNS is globally routable; mixed public/private answers are rejected rather than gambling
/// on which address URLSession will select.
///
/// Platform boundary: URLSession does not expose an API to pin a validated address while retaining its
/// TLS, proxy, and content-decoding stack. It performs its own lookup just after this preflight, leaving a
/// narrow DNS-rebinding/TOCTOU window. A fresh session per hop prevents stale connection reuse, but fully
/// closing that window would require an IP-pinned Network.framework HTTP/TLS transport.
struct WebURLPolicy: Sendable {
    private let resolve: WebDNSResolver

    init(resolve: @escaping WebDNSResolver = SystemDNSResolver.live) {
        self.resolve = resolve
    }

    func validate(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased() else { throw WebNetworkError.invalidURL }
        guard scheme == "http" || scheme == "https" else { throw WebNetworkError.unsupportedScheme }
        guard url.user == nil, url.password == nil else { throw WebNetworkError.invalidURL }
        guard let rawHost = url.host, !rawHost.isEmpty else { throw WebNetworkError.missingHost }

        let host = Self.normalizedHost(rawHost)
        guard !Self.isBlockedLocalName(host) else { throw WebNetworkError.blockedHost }

        if let address = IPAddress.parse(host) {
            guard address.isPublic else { throw WebNetworkError.blockedHost }
            return
        }

        let resolved: [String]
        do {
            resolved = try await resolve(host)
        } catch {
            throw WebNetworkError.dnsResolutionFailed
        }
        guard !resolved.isEmpty else { throw WebNetworkError.dnsResolutionFailed }
        for rawAddress in resolved {
            guard let address = IPAddress.parse(rawAddress), address.isPublic else {
                throw WebNetworkError.blockedHost
            }
        }
    }

    static func isBlockedHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        if isBlockedLocalName(host) { return true }
        guard let address = IPAddress.parse(host) else { return false }
        return !address.isPublic
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isBlockedLocalName(_ host: String) -> Bool {
        host.isEmpty
            || host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "local"
            || host.hasSuffix(".local")
            || host == "home.arpa"
            || host.hasSuffix(".home.arpa")
    }
}

/// The result of one bounded HTTP request. Redirects are deliberately not followed by the transport;
/// `WebHTTPClient` validates the next target, then starts a separate request.
struct WebHTTPResponse: @unchecked Sendable {
    let response: HTTPURLResponse
    let body: Data
    let wasTruncated: Bool
}

struct WebHTTPTransport: Sendable {
    let load: @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> WebHTTPResponse

    static func urlSession(_ session: URLSession) -> Self {
        let configuration = URLSessionConfigurationBox(session.configuration)
        return WebHTTPTransport { request, maxBytes in
            try await BoundedURLSessionRequest(
                configuration: configuration.value,
                maxBytes: maxBytes
            ).start(request)
        }
    }
}

/// Safe, bounded GET client used by both web tools. Redirects are handled manually so no target can be
/// contacted before its scheme, hostname, and resolved addresses pass the same policy as the initial URL.
struct WebHTTPClient: Sendable {
    private let policy: WebURLPolicy
    private let transport: WebHTTPTransport
    private let maxRedirects: Int

    init(session: URLSession = .shared,
         resolver: @escaping WebDNSResolver = SystemDNSResolver.live,
         maxRedirects: Int = 5) {
        self.init(policy: WebURLPolicy(resolve: resolver),
                  transport: .urlSession(session),
                  maxRedirects: maxRedirects)
    }

    init(policy: WebURLPolicy, transport: WebHTTPTransport, maxRedirects: Int = 5) {
        self.policy = policy
        self.transport = transport
        self.maxRedirects = max(0, maxRedirects)
    }

    func get(_ originalRequest: URLRequest, maxBytes: Int) async throws -> WebHTTPResponse {
        guard maxBytes > 0, originalRequest.url != nil else { throw WebNetworkError.invalidURL }

        var request = originalRequest
        var visited = Set<String>()
        var redirectCount = 0

        while let url = request.url {
            do {
                try await policy.validate(url)
            } catch {
                if redirectCount > 0 { throw WebNetworkError.unsafeRedirect }
                throw error
            }

            let key = url.absoluteString
            guard visited.insert(key).inserted else { throw WebNetworkError.tooManyRedirects }

            let result = try await transport.load(request, maxBytes)
            guard Self.isRedirect(result.response.statusCode),
                  let location = result.response.value(forHTTPHeaderField: "Location") else {
                return result
            }

            guard redirectCount < maxRedirects else { throw WebNetworkError.tooManyRedirects }
            guard let nextURL = URL(string: location, relativeTo: url)?.absoluteURL else {
                throw WebNetworkError.invalidRedirect
            }
            redirectCount += 1
            request = Self.redirectedRequest(from: request, to: nextURL)
        }
        throw WebNetworkError.invalidURL
    }

    private static func isRedirect(_ status: Int) -> Bool {
        status == 301 || status == 302 || status == 303 || status == 307 || status == 308
    }

    private static func redirectedRequest(from request: URLRequest, to url: URL) -> URLRequest {
        var next = request
        let crossesOrigin = request.url?.scheme?.lowercased() != url.scheme?.lowercased()
            || request.url?.host?.lowercased() != url.host?.lowercased()
            || request.url?.port != url.port
        next.url = url
        next.httpMethod = "GET"
        next.httpBody = nil
        next.httpBodyStream = nil
        if crossesOrigin {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        return next
    }
}

private final class URLSessionConfigurationBox: @unchecked Sendable {
    let value: URLSessionConfiguration
    init(_ value: URLSessionConfiguration) { self.value = value }
}

/// One URLSession request with a streaming byte ceiling. URLSession delivers data incrementally to this
/// delegate; once the ceiling is reached the task is cancelled immediately and only the bounded prefix is
/// returned. Automatic redirects are stopped before URLSession can contact the next host.
private final class BoundedURLSessionRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maxBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<WebHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false
    private var cancellationRequested = false

    init(configuration: URLSessionConfiguration, maxBytes: Int) {
        self.configuration = configuration
        self.maxBytes = max(1, maxBytes)
    }

    func start(_ request: URLRequest) async throws -> WebHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancellationRequested {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.name = "mobileLLM.web-request"
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Returning nil is the critical redirect seam: the caller receives the 3xx response and validates
        // `Location` before starting another request. No redirect target is contacted automatically.
        completionHandler(nil)
        complete(.success(WebHTTPResponse(response: response, body: Data(), wasTruncated: false)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(WebNetworkError.badResponse))
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let remaining = maxBytes - body.count
        guard remaining > 0 else {
            finishAtLimit(dataTask)
            return
        }
        body.append(data.prefix(remaining))
        if data.count >= remaining {
            // Treat an exact hit as conservatively truncated: waiting for another byte could leave a
            // cap-sized response open until timeout, while completing now guarantees prompt cancellation.
            finishAtLimit(dataTask)
        }
    }

    private func finishAtLimit(_ task: URLSessionDataTask) {
        guard let response else {
            task.cancel()
            complete(.failure(WebNetworkError.badResponse))
            return
        }
        complete(.success(WebHTTPResponse(response: response, body: body, wasTruncated: true)))
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
        } else if let response {
            complete(.success(WebHTTPResponse(response: response, body: body, wasTruncated: false)))
        } else {
            complete(.failure(WebNetworkError.badResponse))
        }
    }

    private func complete(_ result: Result<WebHTTPResponse, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

private enum SystemDNSResolver {
    static let live: WebDNSResolver = { host in
        try await resolve(host)
    }

    private static func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP

            var first: UnsafeMutablePointer<addrinfo>?
            let result = getaddrinfo(host, nil, &hints, &first)
            guard result == 0, let first else { throw WebNetworkError.dnsResolutionFailed }
            defer { freeaddrinfo(first) }

            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor?.pointee {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    info.ai_addr,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    addresses.append(String(cString: buffer))
                }
                cursor = info.ai_next
            }
            return Array(Set(addresses))
        }.value
    }
}

private enum IPAddress {
    case v4([UInt8])
    case v6([UInt8])

    static func parse(_ raw: String) -> IPAddress? {
        let withoutZone = raw.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? raw

        var v4 = in_addr()
        if withoutZone.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return .v4(withUnsafeBytes(of: &v4) { Array($0) })
        }

        var v6 = in6_addr()
        if withoutZone.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return .v6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        return nil
    }

    var isPublic: Bool {
        switch self {
        case .v4(let bytes):
            return Self.isPublicIPv4(bytes)
        case .v6(let bytes):
            return Self.isPublicIPv6(bytes)
        }
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false }       // shared CGNAT
        if b[0] == 169 && b[1] == 254 { return false }                    // link-local
        if b[0] == 172 && (16...31).contains(b[1]) { return false }       // RFC 1918
        if b[0] == 192 && b[1] == 168 { return false }                    // RFC 1918
        if b[0] == 192 && b[1] == 0 && b[2] == 0 { return false }         // IETF protocol assignments
        if b[0] == 192 && b[1] == 0 && b[2] == 2 { return false }         // TEST-NET-1
        if b[0] == 192 && b[1] == 88 && b[2] == 99 { return false }       // deprecated 6to4 relay
        if b[0] == 198 && (b[1] == 18 || b[1] == 19) { return false }     // benchmarking
        if b[0] == 198 && b[1] == 51 && b[2] == 100 { return false }      // TEST-NET-2
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }       // TEST-NET-3
        return true
    }

    private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }

        // IPv4-compatible and IPv4-mapped forms inherit the embedded IPv4 address's classification.
        if b[0..<12].allSatisfy({ $0 == 0 })
            || (b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff) {
            return isPublicIPv4(Array(b[12..<16]))
        }

        // The well-known NAT64 prefix also carries an IPv4 destination in the final 32 bits.
        let nat64Prefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
        if Array(b[0..<12]) == nat64Prefix {
            return isPublicIPv4(Array(b[12..<16]))
        }

        if b.allSatisfy({ $0 == 0 }) { return false }                    // unspecified
        if b[0] == 0xff { return false }                                 // multicast
        if b[0] & 0xfe == 0xfc { return false }                          // unique-local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }          // link-local
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }          // deprecated site-local

        // Only currently allocated global-unicast space is eligible.
        guard b[0] & 0xe0 == 0x20 else { return false }

        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 {
            return false                                                  // documentation
        }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 {
            return false                                                  // Teredo
        }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x02 {
            return false                                                  // benchmarking
        }
        if b[0] == 0x20 && b[1] == 0x02 {
            return false                                                  // deprecated 6to4
        }
        let first28 = (UInt32(b[0]) << 20) | (UInt32(b[1]) << 12)
            | (UInt32(b[2]) << 4) | UInt32(b[3] >> 4)
        if first28 == 0x2001001 || first28 == 0x2001002 {
            return false                                                  // ORCHID / ORCHIDv2
        }
        return true
    }
}

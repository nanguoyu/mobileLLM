// SPDX-License-Identifier: MIT

import Foundation

#if DEBUG
/// Deterministic Responses API transport used only by the opt-in simulator UI test. It exercises
/// the production provider parser, durable executor, analyzer, automatic one-run approval, and engine
/// without making release-gating UI behavior depend on a live model's latency or output quality.
private final class DynamicWorkflowUITestResponsesProtocol: URLProtocol, @unchecked Sendable {
    private static let environmentKey = "MOBILELLM_DYNAMIC_WORKFLOW_RESPONSES_FIXTURE"

    override class func canInit(with request: URLRequest) -> Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.path.hasSuffix("/responses") || url.path.hasSuffix("/chat/completions") else {
            // The opt-in fixture owns its entire session. Unknown paths fail here instead of
            // falling through to a real provider when the developer's configured dialect changes.
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.requestBodyString(request)
        let text: String
        if body.contains("MOBILELLM_ACCEPTANCE_REVIEW_V1") {
            text = #"{"approved":true,"checks":[{"criterionID":"feasibility","status":"satisfied","evidence":"The fixture draft gives a constraint-based verdict and alternatives."}],"issues":[]}"#
        } else if body.contains("MOBILELLM_DRAFT_V1") {
            text = "EVAL_KIMI_LOCAL: The complete Kimi K3 model as local weights on an iPhone 16 Pro is not feasible under this fixture's assumed memory and storage constraints. Use a smaller local model or a remote API."
        } else if body.contains("MOBILELLM_COORDINATOR_NEXT_V1") {
            text = #"{"action":"deliver","stage":"Deliver","reason":"The three fixture investigations are available.","tasks":[]}"#
        } else if body.contains("MOBILELLM_COORDINATOR_V1") {
            text = #"{"criteria":[{"id":"feasibility","requirement":"Assess the complete local model and give alternatives."}],"decision":{"action":"work","stage":"Investigate","reason":"Independent constraint tracks.","tasks":[{"id":"model","instruction":"Assess model memory constraints.","criteria":["feasibility"],"inputs":[],"consolidatesInputs":false,"maxToolCalls":0},{"id":"device","instruction":"Assess phone constraints.","criteria":["feasibility"],"inputs":[],"consolidatesInputs":false,"maxToolCalls":0},{"id":"alternatives","instruction":"Assess smaller local and remote alternatives.","criteria":["feasibility"],"inputs":[],"consolidatesInputs":false,"maxToolCalls":0}]}}"#
        } else if body.contains("MOBILELLM_WORKER_V1") {
            text = #"{"status":"completed","summary":"Fixture constraints exclude the complete model.","content":"Under the fixture assumptions the phone lacks RAM and storage for complete local weights; consider a smaller local model or remote API.","unresolved":[]}"#
        } else {
            text = "unexpected simulator workflow request"
        }
        do {
            let chat = url.path.hasSuffix("/chat/completions")
            let delta = try JSONSerialization.data(
                withJSONObject: chat
                    ? ["choices": [["delta": ["content": text]]]]
                    : ["type": "response.output_text.delta", "delta": text],
                options: [.sortedKeys]
            )
            let completed = try JSONSerialization.data(
                withJSONObject: chat ? [
                    "choices": [["finish_reason": "stop", "delta": [:]]],
                    "usage": ["prompt_tokens": 16, "completion_tokens": 32],
                ] : [
                    "type": "response.completed",
                    "status": "completed",
                    "usage": ["input_tokens": 16, "output_tokens": 32],
                ],
                options: [.sortedKeys]
            )
            var bytes = Data("data: ".utf8)
            bytes.append(delta)
            bytes.append(Data("\n\ndata: ".utf8))
            bytes.append(completed)
            bytes.append(Data("\n\n".utf8))
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestBodyString(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: capacity)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func session() -> URLSession {
        guard ProcessInfo.processInfo.environment[environmentKey] == "1" else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DynamicWorkflowUITestResponsesProtocol.self]
        return URLSession(configuration: configuration)
    }
}
#endif

func agentRuntimeURLSession() -> URLSession {
    #if DEBUG
    DynamicWorkflowUITestResponsesProtocol.session()
    #else
    .shared
    #endif
}

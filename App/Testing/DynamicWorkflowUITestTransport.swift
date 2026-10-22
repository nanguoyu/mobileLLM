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
            && request.url?.path.hasSuffix("/responses") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.requestBodyString(request)
        let text: String
        if body.contains("KIMI_SYNTHESIS_TRACK") {
            text = """
            EVAL_KIMI_LOCAL: Running the complete Kimi K3 weights entirely offline on an iPhone 16 Pro is not feasible. The phone's RAM and storage are far below the order of magnitude required even after aggressive quantization. Use a much smaller on-device model, or keep Kimi K3 on a remote server/API and make the iPhone a private client.
            """
        } else if body.contains("KIMI_MODEL_TRACK") {
            text = "The full model has an enormous parameter footprint; quantization reduces bytes per weight but does not make phone-class deployment realistic."
        } else if body.contains("IPHONE_LIMIT_TRACK") {
            text = "An iPhone 16 Pro has phone-class unified memory and storage, both orders of magnitude below the complete model's practical runtime requirements."
        } else if body.contains("DEPLOYMENT_PATH_TRACK") {
            text = "Realistic paths are a smaller local model for offline work or a remote Kimi deployment/API with explicit network and privacy controls."
        } else if body.contains("mobileLLM Dynamic Workflow V1")
            || body.contains("Repair one mobileLLM Dynamic Workflow V1")
        {
            text = """
            export const meta = {
              name: "kimi-local-feasibility",
              description: "Researches model scale, device limits, and deployment alternatives before producing a concrete verdict.",
              whenToUse: "A user asks whether a very large model can run fully locally on an iPhone.",
              phases: [
                { title: "Research", detail: "Run three independent constraint tracks in parallel." },
                { title: "Synthesize", detail: "Turn the evidence into a direct deployment verdict." }
              ]
            };
            phase("Research");
            const findings = await parallel([
              () => agent("KIMI_MODEL_TRACK: Estimate the complete Kimi K3 weight and runtime footprint.", { label: "Model scale", phase: "Research" }),
              () => agent("IPHONE_LIMIT_TRACK: Assess iPhone 16 Pro RAM and storage constraints.", { label: "Device limits", phase: "Research" }),
              () => agent("DEPLOYMENT_PATH_TRACK: Identify honest local and remote deployment alternatives.", { label: "Alternatives", phase: "Research" })
            ]);
            phase("Synthesize");
            return await agent(`KIMI_SYNTHESIS_TRACK: Give a direct verdict using all three findings. Preserve the token EVAL_KIMI_LOCAL. Model: ${findings[0]} Device: ${findings[1]} Alternatives: ${findings[2]}`, { label: "Final verdict", phase: "Synthesize" });
            """
        } else {
            text = "unexpected simulator workflow request"
        }
        do {
            let delta = try JSONSerialization.data(
                withJSONObject: ["type": "response.output_text.delta", "delta": text],
                options: [.sortedKeys]
            )
            let completed = try JSONSerialization.data(
                withJSONObject: [
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


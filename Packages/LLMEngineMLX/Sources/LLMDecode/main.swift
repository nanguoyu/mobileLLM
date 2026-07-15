// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import LLMEngineMLX
import LLMCore

// End-to-end gate: download a real Bonsai 1-bit model, load it (fork kernel), and stream a reply
// through MLXLLMEngine — the same actor the app uses. Coherent text = the full stack works.

func err(_ s: String) { FileHandle.standardError.write(s.data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment
let repo = env["DECODE_REPO"] ?? "prism-ml/Bonsai-8B-mlx-1bit"
let promptText = env["DECODE_PROMPT"]
    ?? "Explain in about 80 words, in simple terms, how a neural network learns."
let maxTokens = Int(env["DECODE_MAXTOKENS"] ?? "") ?? 220
let thinking = env["DECODE_THINK"] == "1"
let engine = MLXLLMEngine()

err("▶ Loading \(repo) (first run downloads ~1.3 GB)…\n")
nonisolated(unsafe) var lastPct = -1
try await engine.loadFromHub(repo) { f in
    let p = Int(f * 100)
    if p != lastPct, p % 10 == 0 { lastPct = p; err("  download \(p)%\n") }
}

err("▶ Generating…\n")
let messages = [
    ChatTurn(role: .system, content: "You are a concise, helpful assistant."),
    ChatTurn(role: .user, content: promptText),
]
var params = Sampling()
params.maxTokens = maxTokens
params.thinking = thinking

var answer = "", reasoning = ""
for try await delta in engine.generate(messages: messages, params: params) {
    switch delta {
    case .reasoning(let s): reasoning += s
    case .answer(let s): answer += s; err(s)
    case .done(let stats):
        print("\n──── ANSWER ────\n\(answer.trimmingCharacters(in: .whitespacesAndNewlines))")
        if !reasoning.isEmpty { print("──── reasoning: \(reasoning.count) chars ────") }
        print("──── \(stats.genTokens) tok · \(String(format: "%.1f", stats.tokensPerSecond)) tok/s"
            + " · peak \(stats.peakMemoryBytes / 1_000_000) MB · stop:\(stats.stopReason.rawValue) ────")
    }
}

let ok = answer.filter(\.isLetter).count >= 8
print(ok ? "✅ PASS — Bonsai-8B 1-bit decoded real text end-to-end through MLXLLMEngine."
         : "❌ FAIL — no coherent answer.")
if !ok { exit(1) }

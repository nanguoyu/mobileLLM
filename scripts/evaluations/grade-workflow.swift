// SPDX-License-Identifier: MIT
// Compile with AppUnitTests/WorkflowTaskOracles.swift to apply the SAME outcome checks to saved
// mobileLLM or reference-harness outputs. Execution/authority trace checks remain separate.
import Foundation

@main struct GradeWorkflow {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage: grade-workflow evidence.json", code: 1)
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let name = evidence["case"] as? String, let task = WorkflowLiveCase(rawValue: name) else {
            throw NSError(domain: "Invalid evaluation evidence", code: 1)
        }
        var failures = [String]()
        if let text = evidence["answer"] as? String,
           let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            failures = try task.verify(answer, heldOut: evidence["variant"] as? String == "held-out")
        } else { failures = ["Final answer is not the requested JSON artifact"] }
        let output: [String: Any] = ["case": name, "outcomeChecksPassed": failures.isEmpty, "failures": failures]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

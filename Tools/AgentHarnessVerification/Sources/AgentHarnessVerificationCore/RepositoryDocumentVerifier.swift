// SPDX-License-Identifier: MIT

import Foundation

enum RepositoryDocumentVerifier {
    private struct DocumentFamily {
        let schema: String
        let instances: [String]
    }

    static func verify(root: URL, diagnostics: inout [VerificationDiagnostic]) {
        ArchitectureBoundaryVerifier.verify(root: root, diagnostics: &diagnostics)
        let families = [
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/requirements.schema.json",
                instances: ["Verification/AgentHarness/requirements.v1.json"]
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/tests.schema.json",
                instances: ["Verification/AgentHarness/tests.v1.json"]
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/quarantine.schema.json",
                instances: ["Verification/AgentHarness/quarantine.v1.json"]
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/semantic-registry.schema.json",
                instances: repositoryFiles(root: root, directory: "Verification/AgentHarness/Registries",
                                           extension: "json")
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/scripted-model.schema.json",
                instances: repositoryFiles(root: root, directory: "Verification/AgentHarness/ModelScripts",
                                           extension: "json")
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/app-container.schema.json",
                instances: repositoryFiles(root: root, directory: "Verification/AgentHarness/AppContainers",
                                           extension: "json")
            ),
            DocumentFamily(
                schema: "Verification/AgentHarness/Schemas/coverage-policy.schema.json",
                instances: repositoryFiles(root: root, directory: "Verification/AgentHarness/Coverage",
                                           extension: "json")
            ),
        ]

        for family in families {
            if family.instances.isEmpty {
                add(&diagnostics, "AHV-DISCOVERY-EMPTY", family.schema,
                    "schema family discovered no instance documents")
            }
            guard let schema = loadJSON(path: family.schema, root: root, diagnostics: &diagnostics) else {
                continue
            }
            for issue in RepositoryJSONSchemaValidator.validateSchema(schema, label: family.schema) {
                add(&diagnostics, "AHV-SCHEMA-DEFINITION", issue.location, issue.message)
            }
            for path in family.instances {
                guard let instance = loadJSON(path: path, root: root, diagnostics: &diagnostics) else { continue }
                for issue in RepositoryJSONSchemaValidator.validate(
                    instance: instance, against: schema, label: path
                ) {
                    add(&diagnostics, "AHV-SCHEMA-INSTANCE", issue.location, issue.message)
                }
                validateDeclaredSchema(instance, instancePath: path, expectedSchemaPath: family.schema,
                                       root: root, diagnostics: &diagnostics)
            }
        }
        validateTestPlans(root: root, diagnostics: &diagnostics)
        validateFixtureSemantics(root: root, diagnostics: &diagnostics)
        validateRegistrySemantics(root: root, diagnostics: &diagnostics)
        validateCoverageDocuments(root: root, diagnostics: &diagnostics)
    }

    private static func validateDeclaredSchema(
        _ instance: Any, instancePath: String, expectedSchemaPath: String, root: URL,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        guard let object = instance as? [String: Any], let declaration = object["$schema"] as? String else {
            add(&diagnostics, "AHV-SCHEMA-DECLARATION", instancePath,
                "document must declare its local $schema")
            return
        }
        let instanceDirectory = (instancePath as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: instanceDirectory, relativeTo: root)
            .appending(path: declaration).standardizedFileURL
        let expected = root.appending(path: expectedSchemaPath).standardizedFileURL
        guard isConfined(resolved, to: root), resolved == expected else {
            add(&diagnostics, "AHV-SCHEMA-DECLARATION", instancePath,
                "$schema must resolve to \(expectedSchemaPath)")
            return
        }
    }

    private static func validateFixtureSemantics(root: URL,
                                                 diagnostics: inout [VerificationDiagnostic]) {
        for path in repositoryFiles(root: root, directory: "Verification/AgentHarness/ModelScripts",
                                    extension: "json") {
            guard let object = loadJSON(path: path, root: root, diagnostics: &diagnostics) as? [String: Any],
                  let steps = object["steps"] as? [[String: Any]],
                  let expected = object["expected"] as? [String: Any] else { continue }
            let ordinals = steps.compactMap { ($0["ordinal"] as? NSNumber)?.intValue }
            let expectedOrdinals = steps.isEmpty ? [] : Array(1...steps.count)
            if ordinals != expectedOrdinals {
                add(&diagnostics, "AHV-FIXTURE-ORDER", path,
                    "model-script ordinals must be contiguous and start at one")
            }
            let modelAttempts = steps.filter { $0["kind"] as? String == "modelAttempt" }.count
            let toolOutcomes = steps.filter { $0["kind"] as? String == "toolOutcome" }.count
            let userResponses = steps.filter { $0["kind"] as? String == "userResponse" }.count
            requireCount(expected["modelAttempts"], equals: modelAttempts, name: "modelAttempts",
                         path: path, diagnostics: &diagnostics)
            requireCount(expected["toolInvocations"], equals: toolOutcomes, name: "toolInvocations",
                         path: path, diagnostics: &diagnostics)
            let emissions = steps.flatMap { $0["emissions"] as? [[String: Any]] ?? [] }
            let interactions = emissions.filter { $0["type"] as? String == "requestUserInput" }.count
            requireCount(expected["interactionRequests"], equals: interactions,
                         name: "interactionRequests", path: path, diagnostics: &diagnostics)
            if interactions != userResponses {
                add(&diagnostics, "AHV-FIXTURE-INTERACTION", path,
                    "each scripted interaction request must have one userResponse step")
            }
            let repairs = emissions.filter { $0["type"] as? String == "malformedAction" }.count
            requireCount(expected["structuredRepairs"], equals: repairs,
                         name: "structuredRepairs", path: path, diagnostics: &diagnostics)

            let attempts = steps.filter { $0["kind"] as? String == "modelAttempt" }
            for (index, attempt) in attempts.enumerated() {
                let attemptEmissions = attempt["emissions"] as? [[String: Any]] ?? []
                let terminalIndexes = attemptEmissions.indices.filter { emissionIndex in
                    let type = attemptEmissions[emissionIndex]["type"] as? String
                    return type == "completed" || type == "failed"
                }
                if terminalIndexes.count != 1 || terminalIndexes.first != attemptEmissions.indices.last {
                    add(&diagnostics, "AHV-FIXTURE-TERMINAL", path,
                        "model attempt \(index + 1) must end with exactly one terminal emission")
                }
            }
            if let terminalState = expected["terminalState"] as? String,
               let lastAttempt = attempts.last,
               let lastEmission = (lastAttempt["emissions"] as? [[String: Any]])?.last {
                let expectedEmission = terminalState == "completed" ? "completed" : "failed"
                if lastEmission["type"] as? String != expectedEmission {
                    add(&diagnostics, "AHV-FIXTURE-TERMINAL", path,
                        "last model attempt disagrees with expected.terminalState")
                }
            }
            let answer = emissions.compactMap { emission -> String? in
                emission["type"] as? String == "answerDelta" ? emission["text"] as? String : nil
            }.joined()
            if let expectedAnswer = expected["finalAnswer"] as? String, answer != expectedAnswer {
                add(&diagnostics, "AHV-FIXTURE-ANSWER", path,
                    "answerDelta text must equal expected.finalAnswer")
            }
        }

        let containerPaths = repositoryFiles(root: root,
                                             directory: "Verification/AgentHarness/AppContainers",
                                             extension: "json")
        var scenarios: Set<String> = []
        for path in containerPaths {
            guard let object = loadJSON(path: path, root: root, diagnostics: &diagnostics) as? [String: Any],
                  let scenario = object["scenario"] as? String else { continue }
            if !scenarios.insert(scenario).inserted {
                add(&diagnostics, "AHV-FIXTURE-DUPLICATE", path,
                    "app-container scenario \(scenario) is duplicated")
            }
        }
        for required in ["cleanInstall", "legacyUpgrade"] where !scenarios.contains(required) {
            add(&diagnostics, "AHV-FIXTURE-MISSING", "Verification/AgentHarness/AppContainers",
                "missing required \(required) fixture")
        }
    }

    private static func validateRegistrySemantics(root: URL,
                                                  diagnostics: inout [VerificationDiagnostic]) {
        SemanticRegistryVerifier.verify(root: root, diagnostics: &diagnostics)
    }

    private static func validateCoverageDocuments(root: URL,
                                                  diagnostics: inout [VerificationDiagnostic]) {
        let policyPath = "Verification/AgentHarness/Coverage/policy.v1.json"
        guard let policy = loadJSON(path: policyPath, root: root,
                                    diagnostics: &diagnostics) as? [String: Any],
              let floors = policy["floors"] as? [[String: Any]],
              let semantic = policy["semanticGates"] as? [[String: Any]],
              let mutations = policy["mutationGates"] as? [[String: Any]],
              let collection = policy["collection"] as? [String: Any] else { return }
        var floorByScope: [String: [String: Any]] = [:]
        for floor in floors {
            guard let scope = floor["scope"] as? String else { continue }
            if floorByScope.updateValue(floor, forKey: scope) != nil {
                add(&diagnostics, "AHV-COVERAGE-FLOOR", policyPath,
                    "coverage scope \(scope) is duplicated")
            }
        }
        for scope in ["AgentContracts", "AgentRuntime"] {
            guard let floor = floorByScope[scope],
                  (floor["linePercent"] as? NSNumber)?.doubleValue ?? 0 >= 90,
                  (floor["functionPercent"] as? NSNumber)?.doubleValue ?? 0 >= 90 else {
                add(&diagnostics, "AHV-COVERAGE-FLOOR", policyPath,
                    "\(scope) must enforce at least 90% line and function coverage")
                continue
            }
        }
        guard let critical = floorByScope["security-critical-runtime-components"],
              (critical["linePercent"] as? NSNumber)?.doubleValue ?? 0 >= 95,
              (critical["functionPercent"] as? NSNumber)?.doubleValue == 100 else {
            add(&diagnostics, "AHV-COVERAGE-FLOOR", policyPath,
                "security-critical runtime components require 95% lines and 100% functions")
            return
        }
        if semantic.count < 5 || semantic.contains(where: {
            ($0["requiredPercent"] as? NSNumber)?.intValue != 100
        }) {
            add(&diagnostics, "AHV-COVERAGE-SEMANTIC", policyPath,
                "all semantic gates must require 100 percent")
        }
        if mutations.count < 6 || mutations.contains(where: { $0["mustBeKilled"] as? Bool != true }) {
            add(&diagnostics, "AHV-COVERAGE-MUTATION", policyPath,
                "all required mutation seeds must be present and killed")
        }
        for key in ["missingResultFails", "unexpectedSkipFails", "emptyDiscoveryFails"]
            where collection[key] as? Bool != true {
            add(&diagnostics, "AHV-COVERAGE-COLLECTION", policyPath,
                "collection.\(key) must be true")
        }
    }

    private static func validateTestPlans(root: URL,
                                          diagnostics: inout [VerificationDiagnostic]) {
        let plans: [(path: String, target: String)] = [
            ("Verification/AgentHarness/TestPlans/SimulatorUI.xctestplan", "mobileLLMUITests"),
            ("Verification/AgentHarness/TestPlans/DeviceE2E.xctestplan", "mobileLLMDeviceE2ETests"),
        ]
        for plan in plans {
            guard let object = loadJSON(path: plan.path, root: root,
                                        diagnostics: &diagnostics) as? [String: Any],
                  let options = object["defaultOptions"] as? [String: Any],
                  let targets = object["testTargets"] as? [[String: Any]] else { continue }
            if options["codeCoverage"] as? Bool != true {
                add(&diagnostics, "AHV-TESTPLAN-COVERAGE", plan.path,
                    "code coverage must be enabled")
            }
            if targets.count != 1
                || (targets[0]["parallelizable"] as? Bool) != false
                || ((targets[0]["target"] as? [String: Any])?["name"] as? String) != plan.target {
                add(&diagnostics, "AHV-TESTPLAN-TARGET", plan.path,
                    "plan must contain exactly the serial \(plan.target) target")
            }
        }
        let projectPath = "project.yml"
        guard let project = try? String(contentsOf: root.appending(path: projectPath), encoding: .utf8) else {
            add(&diagnostics, "AHV-TESTPLAN-PROJECT", projectPath, "project.yml is unreadable")
            return
        }
        for plan in plans where !project.contains(plan.path) {
            add(&diagnostics, "AHV-TESTPLAN-PROJECT", projectPath,
                "project.yml does not reference \(plan.path)")
        }
    }

    private static func requireCount(_ value: Any?, equals expected: Int, name: String, path: String,
                                     diagnostics: inout [VerificationDiagnostic]) {
        if (value as? NSNumber)?.intValue != expected {
            add(&diagnostics, "AHV-FIXTURE-EXPECTATION", "\(path).expected.\(name)",
                "expected \(expected) based on scripted steps")
        }
    }

    private static func repositoryFiles(root: URL, directory: String, extension suffix: String) -> [String] {
        let directoryURL = root.appending(path: directory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == suffix }
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            .sorted()
    }

    private static func loadJSON(path: String, root: URL,
                                 diagnostics: inout [VerificationDiagnostic]) -> Any? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            add(&diagnostics, "AHV-JSON-PATH", path, "path must be repository-confined")
            return nil
        }
        let url = root.appending(path: path).standardizedFileURL
        guard isConfined(url, to: root), let data = try? Data(contentsOf: url) else {
            add(&diagnostics, "AHV-JSON-MISSING", path, "JSON document is unreadable")
            return nil
        }
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            add(&diagnostics, "AHV-JSON-DECODE", path, "invalid JSON: \(error.localizedDescription)")
            return nil
        }
    }

    private static func isConfined(_ url: URL, to root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func add(_ diagnostics: inout [VerificationDiagnostic], _ code: String,
                            _ location: String, _ message: String) {
        diagnostics.append(.init(code: code, location: location, message: message))
    }
}

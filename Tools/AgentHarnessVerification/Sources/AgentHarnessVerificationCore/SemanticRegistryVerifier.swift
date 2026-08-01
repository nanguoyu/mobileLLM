// SPDX-License-Identifier: MIT

import Foundation

/// Expands the repository-owned decision tables into their complete finite Cartesian products.
///
/// This is intentionally a verifier for data, not an executable workflow language. Conditions may
/// only select one declared value per finite axis; an omitted axis is a wildcard. A table is valid
/// only when every cell has one highest-priority winner and every rule wins at least one cell.
enum SemanticRegistryVerifier {
    private struct Rule {
        let id: String
        let table: String
        let priority: Int
        let conditions: [String: String]
        let outcome: [String: Any]
    }

    private struct WinningCell {
        let values: [String: String]
        let rule: Rule
    }

    private struct TableEvaluation {
        let table: String
        let rules: [Rule]
        let cells: [WinningCell]
        let winningRuleIDs: Set<String>
    }

    private struct ExpectedOutcome {
        let decision: String
        let scope: String
        let retry: String
        let uncertain: Bool
        let runState: String?
    }

    private static let registryDirectory = "Verification/AgentHarness/Registries"
    private static let expectedRegistryTypes: Set<String> = [
        "run-states", "run-transitions", "approval-decisions", "stable-boundary-faults",
    ]
    private static let runStates: [String] = [
        "created", "preparing", "waitingForModel", "generating", "validatingAction",
        "waitingForApproval", "executingTools", "waitingForUser", "synthesizing", "pausing",
        "paused", "waitingForForeground", "waitingForReconciliation", "completed", "failed",
        "cancelled",
    ]
    private static let terminalStates: Set<String> = ["completed", "failed", "cancelled"]
    private static let commandNames: Set<String> = [
        "pause", "resume", "cancel", "decideApproval", "reconcile", "respond",
    ]
    private static let externalEffects: Set<String> = [
        "externalRead", "externalWrite", "strongExact", "codeExecution", "unknownExternal",
    ]

    private static let runDomains: [String: [String: Set<String>]] = [
        "commandAdmission": [
            "wireValidity": ["valid", "unsupportedVersion", "malformed"],
            "runLookup": ["found", "missing"],
            "deduplication": ["unseen", "identicalReplay", "conflictingReuse"],
            "terminality": ["nonterminal", "terminal"],
            "expectedVersion": ["matching", "stale"],
        ],
        "pauseCancelRouting": [
            "state": Set(runStates),
            "command": ["pause", "cancel"],
            "guard": [
                "safeBoundary", "cancellableWork", "noncancellableExternalIntent",
                "unresolvedExternalOutcome",
            ],
        ],
        "resumeRouting": [
            "state": Set(runStates),
            "guard": ["ready", "foregroundUnavailable", "dependencyUnavailable"],
        ],
        "approvalCommandRouting": [
            "state": Set(runStates),
            "guard": [
                "exactApproved", "conversationReadApproved", "denied", "cancelled", "expired",
                "invalidScope", "planChanged", "systemPermissionReady",
                "systemPermissionPromptForeground", "systemPermissionPromptBackground",
                "systemPermissionDenied",
            ],
        ],
        "responseCommandRouting": [
            "state": Set(runStates),
            "guard": ["valid", "targetMismatch", "schemaInvalid"],
        ],
        "reconciliationCommandRouting": [
            "state": Set(runStates),
            "guard": [
                "succeededProof", "failedProof", "abandonedConfirmed", "targetMismatch",
                "proofInsufficient",
            ],
        ],
        "trustedProgressRouting": [
            "state": Set(runStates),
            "trigger": [
                "beginPreparation", "contextCommitted", "modelLeaseGranted",
                "modelAttemptCompleted", "modelRetryScheduled", "finalAnswerCommitted",
                "toolBatchNeedsApproval", "toolBatchAuthorized", "userInputRequested",
                "repairScheduled", "repairExhausted", "nextToolNeedsApproval",
                "toolBatchCompleted", "toolBatchStopped", "externalOutcomeUnknown",
                "foregroundLost", "systemPermissionResolved",
            ],
            "callbackGuard": [
                "valid", "duplicateOutcome", "staleVersion", "targetMismatch",
                "budgetUnavailable", "dependencyUnavailable", "externalIntentOutstanding",
                "retryBudgetRemaining", "retryBudgetExhausted", "effectOutcomeUncertain",
                "foregroundUnavailable", "systemPermissionGranted", "systemPermissionDenied",
                "systemPermissionPromptRequiredInBackground",
            ],
        ],
        "quiescenceRouting": [
            "state": Set(runStates),
            "quiescenceOutcome": [
                "userPause", "foregroundLost", "backgroundExpired", "cancelled",
                "resourcePressurePaused", "resourcePressureForeground",
                "externalOutcomeUncertain",
            ],
            "callbackGuard": [
                "valid", "duplicateOutcome", "staleVersion", "targetMismatch",
                "externalIntentOutstanding",
            ],
        ],
        "terminalFailureRouting": [
            "state": Set(runStates),
            "failureReason": [
                "budgetExceeded", "noProgress", "permissionDenied", "toolUnavailable",
                "modelUnavailable", "contextUnsatisfiable", "internalFailure",
            ],
            "callbackGuard": [
                "valid", "duplicateOutcome", "staleVersion", "targetMismatch",
                "externalIntentOutstanding",
            ],
        ],
    ]

    private static let receiptValues: Set<String> = [
        "none", "usableExact", "usableConversationRead", "deniedCurrentRequest",
        "cancelledCurrentRequest", "expired", "notYetValid", "policyMismatch",
        "conversationMismatch", "requestMismatch", "invocationMismatch", "planFingerprintMismatch",
        "previewMismatch", "argumentsMismatch", "destinationMismatch", "redirectsMismatch",
        "fallbacksMismatch", "dataCategoriesMismatch", "artifactsMismatch", "workspaceMismatch",
        "authorityConstraintsMismatch", "effectsMismatch", "payloadMismatch",
        "executionConstraintsMismatch", "descriptorMismatch", "schemaMismatch",
        "trustRevisionMismatch", "idempotencyKeyMismatch", "credentialReferenceMismatch",
        "preparedRequestMismatch", "stepGrantMismatch", "runCeilingMismatch",
    ]
    private static let effectValues: Set<String> = [
        "localPure", "appLocalRead", "appLocalWrite", "externalRead", "externalWrite",
        "strongExact", "codeExecution", "unknownExternal",
    ]
    private static let approvalDomains: [String: [String: Set<String>]] = [
        "authorization": [
            "authority": [
                "valid", "missingStepGrant", "outsideRunCeiling", "planOutsideStepGrant",
                "policyRevokedOrUnavailable",
            ],
            "receipt": receiptValues,
            "effectClass": effectValues,
            "feature": ["notApplicable", "enabled", "disabled"],
            "interaction": ["foregroundInteractive", "background"],
        ],
        "approvalPresentation": [
            "authorizationDecision": ["authorized", "approvalRequired", "denied"],
            "interaction": ["foregroundInteractive", "background"],
        ],
        "systemAccess": [
            "systemAccess": [
                "notRequired", "granted", "promptRequired", "denied", "temporarilyUnavailable",
            ],
            "interaction": ["foregroundInteractive", "background"],
        ],
        "retryAndTransportLoss": [
            "effectClass": effectValues,
            "idempotency": [
                "pureRead", "idempotencyKeyRequired", "reconciliationAvailable", "nonIdempotent",
            ],
            "retry": ["never", "boundedExponential"],
            "transportOutcome": ["confirmedSuccess", "confirmedFailure", "transportLost"],
        ],
    ]

    static func verify(root: URL, diagnostics: inout [VerificationDiagnostic]) {
        let paths = registryPaths(root: root)
        var documents: [String: (path: String, object: [String: Any])] = [:]
        for path in paths {
            guard let object = loadObject(path: path, root: root, diagnostics: &diagnostics),
                  let type = object["registryType"] as? String else { continue }
            if documents.updateValue((path, object), forKey: type) != nil {
                add(&diagnostics, "AHV-REGISTRY-DUPLICATE", path,
                    "registry type \(type) is duplicated")
            }
            validateUniqueEntryIDs(object, path: path, diagnostics: &diagnostics)
        }
        if Set(documents.keys) != expectedRegistryTypes {
            add(&diagnostics, "AHV-REGISTRY-DISCOVERY", registryDirectory,
                "registry types must equal \(expectedRegistryTypes.sorted().joined(separator: ", "))")
        }

        let traceability = loadTraceability(root: root, diagnostics: &diagnostics)
        for document in documents.values {
            validateTraceability(
                document.object, path: document.path, knownRequirements: traceability.requirements,
                testRequirements: traceability.testRequirements, diagnostics: &diagnostics
            )
        }

        if let states = documents["run-states"] {
            validateRunStates(states.object, path: states.path, diagnostics: &diagnostics)
        }
        if let faults = documents["stable-boundary-faults"] {
            validateFaults(faults.object, path: faults.path, diagnostics: &diagnostics)
        }
        if let transitions = documents["run-transitions"] {
            let evaluations = validateDecisionRegistry(
                transitions.object, path: transitions.path, expectedDomains: runDomains,
                diagnostics: &diagnostics
            )
            validateRunTransitionSemantics(
                evaluations, stateDocument: documents["run-states"]?.object,
                path: transitions.path, diagnostics: &diagnostics
            )
        }
        if let approvals = documents["approval-decisions"] {
            let evaluations = validateDecisionRegistry(
                approvals.object, path: approvals.path, expectedDomains: approvalDomains,
                diagnostics: &diagnostics
            )
            validateEffectNormalization(approvals.object, path: approvals.path,
                                        diagnostics: &diagnostics)
            validateApprovalSemantics(evaluations, path: approvals.path, diagnostics: &diagnostics)
        }
    }

    private static func validateDecisionRegistry(
        _ object: [String: Any], path: String, expectedDomains: [String: [String: Set<String>]],
        diagnostics: inout [VerificationDiagnostic]
    ) -> [String: TableEvaluation] {
        validateDecisionHeader(object, path: path, diagnostics: &diagnostics)
        guard let rawDomains = object["domains"] as? [[String: Any]],
              let rawEntries = object["entries"] as? [[String: Any]] else {
            add(&diagnostics, "AHV-REGISTRY-STRUCTURE", path,
                "complete decision registry requires domains and entries")
            return [:]
        }

        var actualDomains: [String: [String: [String]]] = [:]
        for (index, domain) in rawDomains.enumerated() {
            let location = "\(path).domains[\(index)]"
            guard let table = domain["table"] as? String,
                  let name = domain["name"] as? String,
                  let values = domain["values"] as? [String], !values.isEmpty else {
                add(&diagnostics, "AHV-REGISTRY-DOMAIN", location,
                    "domain requires table, name, and nonempty string values")
                continue
            }
            if actualDomains[table, default: [:]].updateValue(values, forKey: name) != nil {
                add(&diagnostics, "AHV-REGISTRY-DOMAIN-DUPLICATE", location,
                    "domain \(table).\(name) is duplicated")
            }
            if Set(values).count != values.count {
                add(&diagnostics, "AHV-REGISTRY-DOMAIN-DUPLICATE", location,
                    "domain values must be unique")
            }
        }
        if Set(actualDomains.keys) != Set(expectedDomains.keys) {
            add(&diagnostics, "AHV-REGISTRY-TABLES", path,
                "decision tables do not match the frozen finite table set")
        }
        for (table, expectedAxes) in expectedDomains {
            let actualAxes = actualDomains[table] ?? [:]
            if Set(actualAxes.keys) != Set(expectedAxes.keys) {
                add(&diagnostics, "AHV-REGISTRY-DOMAIN-COVERAGE", "\(path).\(table)",
                    "domain axes do not match the frozen finite axes")
            }
            for (axis, expectedValues) in expectedAxes
                where Set(actualAxes[axis] ?? []) != expectedValues {
                add(&diagnostics, "AHV-REGISTRY-DOMAIN-COVERAGE", "\(path).\(table).\(axis)",
                    "domain values do not match the frozen finite values")
            }
        }

        var rulesByTable: [String: [Rule]] = [:]
        for (index, entry) in rawEntries.enumerated() {
            let location = "\(path).entries[\(index)]"
            guard let id = entry["id"] as? String,
                  let table = entry["table"] as? String,
                  let priorityNumber = entry["priority"] as? NSNumber,
                  let conditions = entry["conditions"] as? [String: String],
                  let outcome = entry["outcome"] as? [String: Any] else {
                add(&diagnostics, "AHV-REGISTRY-RULE", location,
                    "rule requires id, table, integer priority, string conditions, and outcome")
                continue
            }
            let priority = priorityNumber.intValue
            guard let axes = actualDomains[table] else {
                add(&diagnostics, "AHV-REGISTRY-RULE-TABLE", location,
                    "rule references unknown table \(table)")
                continue
            }
            var valid = true
            for (axis, value) in conditions {
                guard let values = axes[axis] else {
                    add(&diagnostics, "AHV-REGISTRY-RULE-AXIS", location,
                        "condition references unknown axis \(axis)")
                    valid = false
                    continue
                }
                if !values.contains(value) {
                    add(&diagnostics, "AHV-REGISTRY-RULE-VALUE", location,
                        "condition value \(axis)=\(value) is outside its finite domain")
                    valid = false
                }
            }
            if valid {
                rulesByTable[table, default: []].append(
                    Rule(id: id, table: table, priority: priority,
                         conditions: conditions, outcome: outcome)
                )
            }
        }

        var result: [String: TableEvaluation] = [:]
        for table in expectedDomains.keys.sorted() {
            let axes = actualDomains[table] ?? [:]
            let rules = rulesByTable[table] ?? []
            let cells = cartesianCells(axes)
            var winners: [WinningCell] = []
            var winningRuleIDs: Set<String> = []
            var gapCount = 0
            var conflictCount = 0
            var firstGap: [String: String]?
            var firstConflict: [String: String]?
            for cell in cells {
                let matching = rules.filter { rule in
                    rule.conditions.allSatisfy { cell[$0.key] == $0.value }
                }
                guard let maximum = matching.map(\.priority).max() else {
                    gapCount += 1
                    if firstGap == nil { firstGap = cell }
                    continue
                }
                let highest = matching.filter { $0.priority == maximum }
                guard highest.count == 1, let winner = highest.first else {
                    conflictCount += 1
                    if firstConflict == nil { firstConflict = cell }
                    continue
                }
                winners.append(.init(values: cell, rule: winner))
                winningRuleIDs.insert(winner.id)
            }
            if gapCount > 0 {
                add(&diagnostics, "AHV-REGISTRY-GAP", "\(path).\(table)",
                    "\(gapCount) finite cells have no winner; first: \(display(firstGap))")
            }
            if conflictCount > 0 {
                add(&diagnostics, "AHV-REGISTRY-PRIORITY-CONFLICT", "\(path).\(table)",
                    "\(conflictCount) cells have multiple highest-priority rules; first: \(display(firstConflict))")
            }
            let dead = Set(rules.map(\.id)).subtracting(winningRuleIDs)
            if !dead.isEmpty {
                add(&diagnostics, "AHV-REGISTRY-DEAD-RULE", "\(path).\(table)",
                    "rules never win a finite cell: \(dead.sorted().joined(separator: ", "))")
            }
            result[table] = .init(table: table, rules: rules, cells: winners,
                                  winningRuleIDs: winningRuleIDs)
        }
        validateEvidence(object, evaluations: result, actualDomains: actualDomains,
                         expectedTables: Set(expectedDomains.keys), path: path,
                         diagnostics: &diagnostics)
        return result
    }

    private static func validateDecisionHeader(
        _ object: [String: Any], path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        if (object["registryVersion"] as? NSNumber)?.intValue != 1
            || object["completeness"] as? String != "complete" {
            add(&diagnostics, "AHV-REGISTRY-INCOMPLETE", path,
                "decision registry must be complete at registryVersion 1")
        }
        let expected: [String: AnyHashable] = [
            "version": 1,
            "precedence": "higherPriorityWins",
            "noMatch": "denyAndEmitDiagnostic",
            "equalPriorityConflict": "registryInvalid",
            "unknownDomainValue": "denyAndEmitDiagnostic",
            "deadRule": "registryInvalid",
        ]
        guard let semantics = object["evaluationSemantics"] as? [String: Any] else {
            add(&diagnostics, "AHV-REGISTRY-EVALUATION", path,
                "decision registry lacks fail-closed evaluation semantics")
            return
        }
        for (key, value) in expected where (semantics[key] as? AnyHashable) != value {
            add(&diagnostics, "AHV-REGISTRY-EVALUATION", "\(path).evaluationSemantics.\(key)",
                "evaluation semantics must be \(value)")
        }
        if object["requirementIDs"] as? [String] != ["AH-INFRA-004"]
            || object["testIDs"] as? [String] != ["AHT-INFRA-003"] {
            add(&diagnostics, "AHV-REGISTRY-INFRA-TRACE", path,
                "complete decision registries must identify their infrastructure proof")
        }
    }

    private static func validateEvidence(
        _ object: [String: Any], evaluations: [String: TableEvaluation],
        actualDomains: [String: [String: [String]]], expectedTables: Set<String>, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        guard let rows = object["enumerationEvidence"] as? [[String: Any]] else {
            add(&diagnostics, "AHV-REGISTRY-EVIDENCE", path,
                "complete decision registry requires enumeration evidence")
            return
        }
        var byTable: [String: [String: Any]] = [:]
        for row in rows {
            guard let table = row["table"] as? String else { continue }
            if byTable.updateValue(row, forKey: table) != nil {
                add(&diagnostics, "AHV-REGISTRY-EVIDENCE", path,
                    "enumeration evidence duplicates table \(table)")
            }
        }
        if Set(byTable.keys) != expectedTables {
            add(&diagnostics, "AHV-REGISTRY-EVIDENCE", path,
                "enumeration evidence must cover each decision table exactly once")
        }
        for table in expectedTables.sorted() {
            guard let row = byTable[table], let evaluation = evaluations[table] else { continue }
            let cellCount = actualDomains[table]?.values.reduce(1) { $0 * $1.count } ?? 0
            let declaredCells = (row["cellCount"] as? NSNumber)?.intValue
            let declaredRules = (row["ruleCount"] as? NSNumber)?.intValue
            let declaredWinners = (row["winningRuleCount"] as? NSNumber)?.intValue
            if declaredCells != cellCount || declaredRules != evaluation.rules.count
                || declaredWinners != evaluation.winningRuleIDs.count {
                add(&diagnostics, "AHV-REGISTRY-EVIDENCE", "\(path).\(table)",
                    "declared cells/rules/winners do not equal \(cellCount)/\(evaluation.rules.count)/\(evaluation.winningRuleIDs.count)")
            }
        }
    }

    private static func validateRunTransitionSemantics(
        _ evaluations: [String: TableEvaluation], stateDocument: [String: Any]?, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        var terminalReasons: Set<String> = []
        if let admission = evaluations["commandAdmission"] {
            for cell in admission.cells {
                let values = cell.values
                let expected: String
                if values["wireValidity"] != "valid" { expected = "rejected" }
                else if values["runLookup"] == "missing" { expected = "rejected" }
                else if values["deduplication"] == "conflictingReuse" { expected = "rejected" }
                else if values["deduplication"] == "identicalReplay" { expected = "replayOriginalReceipt" }
                else if values["terminality"] == "terminal" { expected = "rejected" }
                else if values["expectedVersion"] == "stale" { expected = "stale" }
                else { expected = "proceed" }
                requireRunDisposition(cell, expected: expected, path: path, diagnostics: &diagnostics)
                validateRunOutcomeShape(cell, path: path, diagnostics: &diagnostics)
            }
        }

        var acceptedCommands: [String: Set<String>] = [:]
        validateRunRoutingTable(
            evaluations["pauseCancelRouting"], implicitCommand: nil,
            expected: expectedPauseCancelRoute, acceptedCommands: &acceptedCommands,
            terminalReasons: &terminalReasons, path: path, diagnostics: &diagnostics
        )
        validateRunRoutingTable(
            evaluations["resumeRouting"], implicitCommand: "resume",
            expected: expectedResumeRoute, acceptedCommands: &acceptedCommands,
            terminalReasons: &terminalReasons, path: path, diagnostics: &diagnostics
        )
        validateRunRoutingTable(
            evaluations["approvalCommandRouting"], implicitCommand: "decideApproval",
            expected: expectedApprovalCommandRoute, acceptedCommands: &acceptedCommands,
            terminalReasons: &terminalReasons, path: path, diagnostics: &diagnostics
        )
        validateRunRoutingTable(
            evaluations["responseCommandRouting"], implicitCommand: "respond",
            expected: expectedResponseRoute, acceptedCommands: &acceptedCommands,
            terminalReasons: &terminalReasons, path: path, diagnostics: &diagnostics
        )
        validateRunRoutingTable(
            evaluations["reconciliationCommandRouting"], implicitCommand: "reconcile",
            expected: expectedReconciliationRoute, acceptedCommands: &acceptedCommands,
            terminalReasons: &terminalReasons, path: path, diagnostics: &diagnostics
        )
        if let entries = stateDocument?["entries"] as? [[String: Any]] {
            for entry in entries {
                guard let state = entry["name"] as? String,
                      let declared = entry["allowedUserCommands"] as? [String] else { continue }
                if Set(declared) != (acceptedCommands[state] ?? []) {
                    add(&diagnostics, "AHV-REGISTRY-COMMAND-DRIFT", "\(path).\(state)",
                        "run-state allowed commands differ from commandRouting winners")
                }
            }
        }

        for (table, routes) in [
            ("trustedProgressRouting", expectedProgressRoutes()),
            ("quiescenceRouting", expectedQuiescenceRoutes()),
        ] {
            guard let evaluation = evaluations[table] else { continue }
            for cell in evaluation.cells {
                let expected = routes[finiteCellKey(cell.values)]
                requireRunRoute(cell, expected: expected, path: path, diagnostics: &diagnostics)
                validateRunOutcomeShape(cell, path: path, diagnostics: &diagnostics)
                if let reason = outcomeString(cell, "terminalReason") { terminalReasons.insert(reason) }
            }
        }
        validateGuardDiagnostics(
            evaluations["trustedProgressRouting"], axis: "callbackGuard", expected: [
                "duplicateOutcome": "duplicateOutcome", "staleVersion": "staleCallbackVersion",
                "targetMismatch": "callbackTargetMismatch", "budgetUnavailable": "budgetUnavailable",
                "dependencyUnavailable": "dependencyUnavailable",
                "externalIntentOutstanding": "externalIntentOutstanding",
            ], path: path, diagnostics: &diagnostics
        )
        validateGuardDiagnostics(
            evaluations["quiescenceRouting"], axis: "callbackGuard", expected: [
                "duplicateOutcome": "duplicateQuiescenceOutcome",
                "staleVersion": "staleQuiescenceVersion",
                "targetMismatch": "quiescenceTargetMismatch",
                "externalIntentOutstanding": "externalIntentMustBecomeUncertain",
            ], path: path, diagnostics: &diagnostics
        )
        if let failures = evaluations["terminalFailureRouting"] {
            for cell in failures.cells {
                let state = cell.values["state"] ?? ""
                let valid = cell.values["callbackGuard"] == "valid"
                    && !terminalStates.contains(state) && state != "waitingForReconciliation"
                let reason = cell.values["failureReason"]
                requireRunRoute(cell, expected: valid && reason != nil ? ("failed", reason) : nil,
                                path: path, diagnostics: &diagnostics)
                validateRunOutcomeShape(cell, path: path, diagnostics: &diagnostics)
                if let actual = outcomeString(cell, "terminalReason") { terminalReasons.insert(actual) }
            }
        }
        validateGuardDiagnostics(
            evaluations["terminalFailureRouting"], axis: "callbackGuard", expected: [
                "duplicateOutcome": "duplicateFailureOutcome", "staleVersion": "staleFailureVersion",
                "targetMismatch": "failureTargetMismatch",
                "externalIntentOutstanding": "uncertainExternalIntentCannotFailClosed",
            ], path: path, diagnostics: &diagnostics
        )
        let expectedReasons: Set<String> = [
            "completed", "cancelledByUser", "budgetExceeded", "noProgress", "permissionDenied",
            "toolUnavailable", "modelUnavailable", "contextUnsatisfiable",
            "externalResultUncertain", "internalFailure",
        ]
        if terminalReasons != expectedReasons {
            add(&diagnostics, "AHV-REGISTRY-TERMINAL-COVERAGE", path,
                "accepted routes must enumerate every terminal reason exactly by typed source")
        }
    }

    private static func validateGuardDiagnostics(
        _ evaluation: TableEvaluation?, axis: String, expected: [String: String], path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        guard let evaluation else { return }
        for cell in evaluation.cells {
            guard let value = cell.values[axis], let diagnostic = expected[value] else { continue }
            if outcomeString(cell, "disposition") != "rejected"
                || outcomeString(cell, "diagnostic") != diagnostic {
                semanticMismatch("\(axis)=\(value) must reject with \(diagnostic)", cell: cell,
                                 path: path, diagnostics: &diagnostics)
            }
        }
    }

    private static func validateRunRoutingTable(
        _ evaluation: TableEvaluation?, implicitCommand: String?,
        expected: ([String: String]) -> (String, String?)?,
        acceptedCommands: inout [String: Set<String>], terminalReasons: inout Set<String>,
        path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        guard let evaluation else { return }
        for cell in evaluation.cells {
            requireRunRoute(cell, expected: expected(cell.values), path: path,
                            diagnostics: &diagnostics)
            validateRunOutcomeShape(cell, path: path, diagnostics: &diagnostics)
            if outcomeString(cell, "disposition") == "accepted",
               let state = cell.values["state"],
               let command = implicitCommand ?? cell.values["command"] {
                acceptedCommands[state, default: []].insert(command)
            }
            if let reason = outcomeString(cell, "terminalReason") { terminalReasons.insert(reason) }
        }
    }

    private static func expectedPauseCancelRoute(_ cell: [String: String]) -> (String, String?)? {
        let state = cell["state"] ?? ""
        let command = cell["command"] ?? ""
        let guardValue = cell["guard"] ?? ""
        let active: Set<String> = [
            "preparing", "waitingForModel", "generating", "validatingAction", "executingTools",
            "synthesizing",
        ]
        if command == "pause", active.contains(state) {
            return guardValue == "unresolvedExternalOutcome"
                ? ("waitingForReconciliation", nil) : ("pausing", nil)
        }
        if command == "cancel" {
            if active.contains(state) || state == "pausing" {
                return guardValue == "unresolvedExternalOutcome"
                    ? ("waitingForReconciliation", nil) : ("pausing", nil)
            }
            let immediate: Set<String> = [
                "created", "waitingForApproval", "waitingForUser", "paused", "waitingForForeground",
            ]
            if immediate.contains(state), guardValue != "unresolvedExternalOutcome" {
                return ("cancelled", "cancelledByUser")
            }
        }
        return nil
    }

    private static func expectedResumeRoute(_ cell: [String: String]) -> (String, String?)? {
        guard cell["guard"] == "ready",
              cell["state"] == "paused" || cell["state"] == "waitingForForeground" else { return nil }
        return ("preparing", nil)
    }

    private static func expectedApprovalCommandRoute(_ cell: [String: String]) -> (String, String?)? {
        guard cell["state"] == "waitingForApproval" else { return nil }
        switch cell["guard"] {
        case "exactApproved", "conversationReadApproved", "systemPermissionReady":
            return ("executingTools", nil)
        case "denied", "cancelled": return ("synthesizing", nil)
        case "systemPermissionPromptForeground": return ("waitingForApproval", nil)
        case "systemPermissionPromptBackground": return ("waitingForForeground", nil)
        default: return nil
        }
    }

    private static func expectedResponseRoute(_ cell: [String: String]) -> (String, String?)? {
        cell["state"] == "waitingForUser" && cell["guard"] == "valid"
            ? ("waitingForModel", nil) : nil
    }

    private static func expectedReconciliationRoute(_ cell: [String: String]) -> (String, String?)? {
        guard cell["state"] == "waitingForReconciliation" else { return nil }
        switch cell["guard"] {
        case "succeededProof", "failedProof": return ("synthesizing", nil)
        case "abandonedConfirmed": return ("failed", "externalResultUncertain")
        default: return nil
        }
    }

    private static func expectedProgressRoutes() -> [String: (String, String?)] {
        var result: [String: (String, String?)] = [:]
        func add(_ state: String, _ trigger: String, _ guardValue: String,
                 to: String, reason: String? = nil) {
            result[finiteCellKey(["state": state, "trigger": trigger, "callbackGuard": guardValue])] =
                (to, reason)
        }
        add("created", "beginPreparation", "valid", to: "preparing")
        add("preparing", "contextCommitted", "valid", to: "waitingForModel")
        add("waitingForModel", "modelLeaseGranted", "valid", to: "generating")
        add("synthesizing", "modelLeaseGranted", "valid", to: "generating")
        add("generating", "modelAttemptCompleted", "valid", to: "validatingAction")
        add("generating", "modelRetryScheduled", "retryBudgetRemaining", to: "waitingForModel")
        add("validatingAction", "finalAnswerCommitted", "valid", to: "completed", reason: "completed")
        add("validatingAction", "toolBatchNeedsApproval", "valid", to: "waitingForApproval")
        add("validatingAction", "toolBatchAuthorized", "valid", to: "executingTools")
        add("validatingAction", "userInputRequested", "valid", to: "waitingForUser")
        add("validatingAction", "repairScheduled", "retryBudgetRemaining", to: "waitingForModel")
        add("validatingAction", "repairExhausted", "retryBudgetExhausted",
            to: "failed", reason: "internalFailure")
        add("executingTools", "nextToolNeedsApproval", "valid", to: "waitingForApproval")
        add("executingTools", "toolBatchCompleted", "valid", to: "waitingForModel")
        add("executingTools", "toolBatchStopped", "valid", to: "synthesizing")
        add("executingTools", "externalOutcomeUnknown", "effectOutcomeUncertain",
            to: "waitingForReconciliation")
        for state in ["preparing", "waitingForModel", "generating", "synthesizing"] {
            add(state, "foregroundLost", "foregroundUnavailable", to: "waitingForForeground")
        }
        add("waitingForApproval", "systemPermissionResolved",
            "systemPermissionPromptRequiredInBackground", to: "waitingForForeground")
        add("waitingForForeground", "systemPermissionResolved", "systemPermissionGranted",
            to: "preparing")
        add("waitingForForeground", "systemPermissionResolved", "systemPermissionDenied",
            to: "failed", reason: "permissionDenied")
        return result
    }

    private static func expectedQuiescenceRoutes() -> [String: (String, String?)] {
        var result: [String: (String, String?)] = [:]
        func add(_ outcome: String, to: String, reason: String? = nil) {
            result[finiteCellKey([
                "state": "pausing", "quiescenceOutcome": outcome, "callbackGuard": "valid",
            ])] = (to, reason)
        }
        add("userPause", to: "paused")
        add("foregroundLost", to: "waitingForForeground")
        add("backgroundExpired", to: "waitingForForeground")
        add("cancelled", to: "cancelled", reason: "cancelledByUser")
        add("resourcePressurePaused", to: "paused")
        add("resourcePressureForeground", to: "waitingForForeground")
        add("externalOutcomeUncertain", to: "waitingForReconciliation")
        return result
    }

    private static func requireRunRoute(
        _ cell: WinningCell, expected: (String, String?)?, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let disposition = outcomeString(cell, "disposition")
        let next = outcomeString(cell, "nextState")
        let reason = outcomeString(cell, "terminalReason")
        if let expected {
            if disposition != "accepted" || next != expected.0 || reason != expected.1 {
                semanticMismatch("run route must accept to \(expected.0)", cell: cell,
                                 path: path, diagnostics: &diagnostics)
            }
        } else if disposition != "rejected" || next != nil || reason != nil {
            semanticMismatch("unregistered run route must reject", cell: cell,
                             path: path, diagnostics: &diagnostics)
        }
    }

    private static func requireRunDisposition(
        _ cell: WinningCell, expected: String, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        if outcomeString(cell, "disposition") != expected {
            semanticMismatch("expected admission disposition \(expected)", cell: cell,
                             path: path, diagnostics: &diagnostics)
        }
    }

    private static func validateRunOutcomeShape(
        _ cell: WinningCell, path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        let disposition = outcomeString(cell, "disposition")
        let next = outcomeString(cell, "nextState")
        let reason = outcomeString(cell, "terminalReason")
        let diagnostic = outcomeString(cell, "diagnostic")
        if disposition == "accepted" {
            if next == nil || diagnostic != nil {
                semanticMismatch("accepted transition requires a destination and no diagnostic",
                                 cell: cell, path: path, diagnostics: &diagnostics)
            }
            switch next {
            case "completed" where reason != "completed",
                 "cancelled" where reason != "cancelledByUser":
                semanticMismatch("terminal destination has the wrong reason", cell: cell,
                                 path: path, diagnostics: &diagnostics)
            case "failed" where reason == nil || reason == "completed" || reason == "cancelledByUser":
                semanticMismatch("failed destination requires a failure terminal reason", cell: cell,
                                 path: path, diagnostics: &diagnostics)
            case let value? where !terminalStates.contains(value) && reason != nil:
                semanticMismatch("nonterminal destination cannot carry a terminal reason", cell: cell,
                                 path: path, diagnostics: &diagnostics)
            default: break
            }
        } else if next != nil || reason != nil {
            semanticMismatch("non-transition dispositions cannot change durable state", cell: cell,
                             path: path, diagnostics: &diagnostics)
        } else if (disposition == "rejected" || disposition == "stale") && diagnostic == nil {
            semanticMismatch("failed-closed disposition requires a stable diagnostic", cell: cell,
                             path: path, diagnostics: &diagnostics)
        }
    }

    private static func validateApprovalSemantics(
        _ evaluations: [String: TableEvaluation], path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        if let authorization = evaluations["authorization"] {
            for cell in authorization.cells {
                compareApproval(cell, expected: expectedAuthorization(cell.values), path: path,
                                diagnostics: &diagnostics)
            }
        }
        if let presentation = evaluations["approvalPresentation"] {
            for cell in presentation.cells {
                let required = cell.values["authorizationDecision"] == "approvalRequired"
                let background = cell.values["interaction"] == "background"
                let expected: ExpectedOutcome
                if required {
                    expected = .init(decision: background ? "deferApproval" : "presentApproval",
                                     scope: "none", retry: "none", uncertain: false,
                                     runState: "waitingForApproval")
                } else {
                    expected = .init(decision: "noPresentation", scope: "none", retry: "none",
                                     uncertain: false, runState: nil)
                }
                compareApproval(cell, expected: expected, path: path, diagnostics: &diagnostics)
            }
        }
        if let system = evaluations["systemAccess"] {
            for cell in system.cells {
                compareApproval(cell, expected: expectedSystemAccess(cell.values), path: path,
                                diagnostics: &diagnostics)
            }
        }
        if let retry = evaluations["retryAndTransportLoss"] {
            for cell in retry.cells {
                compareApproval(cell, expected: expectedRetry(cell.values), path: path,
                                diagnostics: &diagnostics)
            }
        }
    }

    private static func expectedAuthorization(_ cell: [String: String]) -> ExpectedOutcome {
        guard cell["authority"] == "valid" else {
            return .init(decision: "deny", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        }
        guard cell["feature"] != "disabled" else {
            return .init(decision: "deny", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        }
        if cell["receipt"] == "deniedCurrentRequest" || cell["receipt"] == "cancelledCurrentRequest" {
            return .init(decision: "deny", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        }
        let effect = cell["effectClass"] ?? ""
        let isPotentiallySideEffecting = [
            "externalWrite", "strongExact", "codeExecution", "unknownExternal",
        ].contains(effect)
        if externalEffects.contains(effect), cell["receipt"] == "usableExact" {
            return .init(decision: "authorizeMatchingReceipt", scope: "exactInvocation",
                         retry: "none", uncertain: isPotentiallySideEffecting, runState: nil)
        }
        if effect == "externalRead", cell["receipt"] == "usableConversationRead" {
            return .init(decision: "authorizeMatchingReceipt", scope: "boundedConversationRead",
                         retry: "none", uncertain: false, runState: nil)
        }
        if externalEffects.contains(effect) {
            return .init(decision: "requireApproval",
                         scope: effect == "externalRead" ? "boundedConversationRead" : "exactInvocation",
                         retry: "none", uncertain: isPotentiallySideEffecting,
                         runState: "waitingForApproval")
        }
        return .init(decision: "authorizeLocalPolicy", scope: "none", retry: "none",
                     uncertain: false, runState: nil)
    }

    private static func expectedSystemAccess(_ cell: [String: String]) -> ExpectedOutcome {
        switch cell["systemAccess"] {
        case "notRequired", "granted":
            return .init(decision: "continue", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        case "denied":
            return .init(decision: "deny", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        case "temporarilyUnavailable":
            return .init(decision: "waitForForeground", scope: "none", retry: "none",
                         uncertain: false, runState: "waitingForForeground")
        case "promptRequired" where cell["interaction"] == "foregroundInteractive":
            return .init(decision: "requestSystemPrompt", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        default:
            return .init(decision: "waitForForeground", scope: "none", retry: "none",
                         uncertain: false, runState: "waitingForForeground")
        }
    }

    private static func expectedRetry(_ cell: [String: String]) -> ExpectedOutcome {
        let effect = cell["effectClass"] ?? ""
        let transport = cell["transportOutcome"] ?? ""
        if transport == "confirmedSuccess" {
            return .init(decision: "complete", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        }
        if transport == "confirmedFailure" {
            if effect == "externalRead", cell["idempotency"] == "pureRead",
               cell["retry"] == "boundedExponential" {
                return .init(decision: "retrySameOperation", scope: "none",
                             retry: "boundedExponential", uncertain: false, runState: nil)
            }
            return .init(decision: "failKnownNoEffect", scope: "none", retry: "none",
                         uncertain: false, runState: nil)
        }
        if ["unknownExternal", "strongExact", "codeExecution"].contains(effect) {
            return .init(decision: "waitForReconciliation", scope: "none", retry: "none",
                         uncertain: true, runState: "waitingForReconciliation")
        }
        if effect == "externalWrite" {
            if cell["idempotency"] == "idempotencyKeyRequired",
               cell["retry"] == "boundedExponential" {
                return .init(decision: "retrySameOperation", scope: "none",
                             retry: "boundedExponential", uncertain: false, runState: nil)
            }
            return .init(decision: "waitForReconciliation", scope: "none", retry: "none",
                         uncertain: true, runState: "waitingForReconciliation")
        }
        if effect == "externalRead", cell["idempotency"] == "pureRead",
           cell["retry"] == "boundedExponential" {
            return .init(decision: "retrySameOperation", scope: "none",
                         retry: "boundedExponential", uncertain: false, runState: nil)
        }
        return .init(decision: "failKnownNoEffect", scope: "none", retry: "none",
                     uncertain: false, runState: nil)
    }

    private static func compareApproval(
        _ cell: WinningCell, expected: ExpectedOutcome, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let actualDecision = outcomeString(cell, "decision")
        let actualScope = outcomeString(cell, "grantScope")
        let actualRetry = outcomeString(cell, "retryDirective")
        let actualUncertain = cell.rule.outcome["uncertainOnTransportLoss"] as? Bool
        let actualState = outcomeString(cell, "runState")
        if actualDecision != expected.decision || actualScope != expected.scope
            || actualRetry != expected.retry || actualUncertain != expected.uncertain
            || actualState != expected.runState {
            semanticMismatch(
                "approval outcome must be \(expected.decision)/\(expected.scope)/\(expected.retry)/\(expected.uncertain)/\(expected.runState ?? "none")",
                cell: cell, path: path, diagnostics: &diagnostics
            )
        }
    }

    private static func validateEffectNormalization(
        _ object: [String: Any], path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        let expected: [(Int, String, Set<String>)] = [
            (8, "unknownExternal", ["unknownExternal"]),
            (7, "strongExact", ["destructive", "financial", "externalCommunication"]),
            (6, "codeExecution", ["codeExecution"]),
            (5, "externalWrite", ["externalWrite"]),
            (4, "appLocalWrite", ["localWrite"]),
            (3, "externalRead", ["privateDataRead", "networkRead"]),
            (2, "appLocalRead", ["localRead"]),
            (1, "localPure", ["localPure"]),
        ]
        guard let normalization = object["effectNormalization"] as? [String: Any],
              normalization["inputSemantics"] as? String == "setOfTrustedObservedEffects",
              normalization["outputSemantics"] as? String == "highestRiskWins",
              let classes = normalization["classes"] as? [[String: Any]], classes.count == expected.count else {
            add(&diagnostics, "AHV-REGISTRY-EFFECT-NORMALIZATION", path,
                "trusted effect normalization is missing or incomplete")
            return
        }
        let actual = classes.compactMap { row -> (Int, String, Set<String>)? in
            guard let rank = (row["rank"] as? NSNumber)?.intValue,
                  let effect = row["effectClass"] as? String,
                  let sources = row["sourceEffects"] as? [String] else { return nil }
            return (rank, effect, Set(sources))
        }.sorted { $0.0 > $1.0 }
        let valid = actual.count == expected.count && zip(actual, expected).allSatisfy { pair in
            pair.0.0 == pair.1.0 && pair.0.1 == pair.1.1 && pair.0.2 == pair.1.2
        }
        if !valid {
            add(&diagnostics, "AHV-REGISTRY-EFFECT-NORMALIZATION", path,
                "effect sets must normalize by the frozen highest-risk precedence")
        }
    }

    private static func validateRunStates(
        _ object: [String: Any], path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        if object["completeness"] as? String != "complete" {
            add(&diagnostics, "AHV-REGISTRY-INCOMPLETE", path,
                "run-states registry must be complete")
        }
        guard let entries = object["entries"] as? [[String: Any]] else { return }
        let names = entries.compactMap { $0["name"] as? String }
        if Set(names) != Set(runStates) || names.count != runStates.count {
            add(&diagnostics, "AHV-REGISTRY-STATE-COVERAGE", path,
                "run-state registry must contain every frozen state exactly once")
        }
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let terminal = entry["terminal"] as? Bool,
                  let resumable = entry["resumable"] as? Bool,
                  let ownsSlot = entry["ownsExecutionSlot"] as? Bool,
                  let commands = entry["allowedUserCommands"] as? [String] else { continue }
            if terminal != terminalStates.contains(name)
                || (terminal && (resumable || ownsSlot || !commands.isEmpty))
                || !Set(commands).isSubset(of: commandNames) {
                add(&diagnostics, "AHV-REGISTRY-STATE-INVARIANT", "\(path).\(name)",
                    "terminal, resumable, slot, or command invariants are inconsistent")
            }
            if name == "waitingForReconciliation", Set(commands) != ["reconcile"] {
                add(&diagnostics, "AHV-REGISTRY-STATE-INVARIANT", "\(path).\(name)",
                    "uncertain work may only receive an explicit reconcile command")
            }
        }
    }

    private static func validateFaults(
        _ object: [String: Any], path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        if object["completeness"] as? String != "complete" {
            add(&diagnostics, "AHV-REGISTRY-INCOMPLETE", path,
                "stable-boundary-faults registry must be complete")
        }
        guard let entries = object["entries"] as? [[String: Any]] else { return }
        let keys = entries.compactMap { entry -> String? in
            guard let ordinal = (entry["boundaryOrdinal"] as? NSNumber)?.intValue,
                  let phase = entry["phase"] as? String else { return nil }
            return "\(ordinal):\(phase)"
        }
        let expected = Set((1...10).flatMap { ["\($0):before", "\($0):after"] })
        if Set(keys) != expected || keys.count != expected.count {
            add(&diagnostics, "AHV-REGISTRY-FAULT-COVERAGE", path,
                "fault registry must contain before and after for each stable boundary 1...10")
        }
    }

    private static func validateUniqueEntryIDs(
        _ object: [String: Any], path: String, diagnostics: inout [VerificationDiagnostic]
    ) {
        guard let entries = object["entries"] as? [[String: Any]] else { return }
        let ids = entries.compactMap { $0["id"] as? String }
        if Set(ids).count != ids.count {
            add(&diagnostics, "AHV-REGISTRY-ID-DUPLICATE", path,
                "registry entry identifiers must be unique")
        }
    }

    private static func loadTraceability(
        root: URL, diagnostics: inout [VerificationDiagnostic]
    ) -> (requirements: Set<String>, testRequirements: [String: Set<String>]) {
        let requirementPath = "Verification/AgentHarness/requirements.v1.json"
        let testsPath = "Verification/AgentHarness/tests.v1.json"
        let requirementObject = loadObject(path: requirementPath, root: root,
                                           diagnostics: &diagnostics)
        let testsObject = loadObject(path: testsPath, root: root, diagnostics: &diagnostics)
        let requirements = Set(
            (requirementObject?["requirements"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
        )
        var testRequirements: [String: Set<String>] = [:]
        for test in testsObject?["tests"] as? [[String: Any]] ?? [] {
            guard let id = test["id"] as? String,
                  let requirementIDs = test["requirementIDs"] as? [String] else { continue }
            testRequirements[id] = Set(requirementIDs)
        }
        return (requirements, testRequirements)
    }

    private static func validateTraceability(
        _ object: [String: Any], path: String, knownRequirements: Set<String>,
        testRequirements: [String: Set<String>], diagnostics: inout [VerificationDiagnostic]
    ) {
        var records: [(String, [String: Any])] = [(path, object)]
        if let entries = object["entries"] as? [[String: Any]] {
            records += entries.enumerated().map { ("\(path).entries[\($0.offset)]", $0.element) }
        }
        for (location, record) in records {
            guard let requirementIDs = record["requirementIDs"] as? [String],
                  let testIDs = record["testIDs"] as? [String] else {
                if record["registryType"] as? String == "run-transitions"
                    || record["registryType"] as? String == "approval-decisions" {
                    add(&diagnostics, "AHV-REGISTRY-TRACE", location,
                        "complete decision registry requires explicit traceability")
                }
                continue
            }
            for requirement in requirementIDs where !knownRequirements.contains(requirement) {
                add(&diagnostics, "AHV-REGISTRY-TRACE", location,
                    "references unknown requirement \(requirement)")
            }
            for test in testIDs where testRequirements[test] == nil {
                add(&diagnostics, "AHV-REGISTRY-TRACE", location,
                    "references unknown test \(test)")
            }
            for requirement in requirementIDs where !testIDs.contains(where: {
                testRequirements[$0]?.contains(requirement) == true
            }) {
                add(&diagnostics, "AHV-REGISTRY-TRACE", location,
                    "requirement \(requirement) has no linked test in this registry record")
            }
            for test in testIDs where (testRequirements[test] ?? []).isDisjoint(with: requirementIDs) {
                add(&diagnostics, "AHV-REGISTRY-TRACE", location,
                    "test \(test) has no linked requirement in this registry record")
            }
        }
    }

    private static func cartesianCells(_ axes: [String: [String]]) -> [[String: String]] {
        var cells: [[String: String]] = [[:]]
        for name in axes.keys.sorted() {
            let values = (axes[name] ?? []).sorted()
            cells = cells.flatMap { partial in
                values.map { value in
                    var result = partial
                    result[name] = value
                    return result
                }
            }
        }
        return cells
    }

    private static func finiteCellKey(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "|")
    }

    private static func outcomeString(_ cell: WinningCell, _ key: String) -> String? {
        cell.rule.outcome[key] is NSNull ? nil : cell.rule.outcome[key] as? String
    }

    private static func semanticMismatch(
        _ message: String, cell: WinningCell, path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        add(&diagnostics, "AHV-REGISTRY-SECURITY", "\(path).\(cell.rule.table).\(cell.rule.id)",
            "\(message); cell: \(display(cell.values))")
    }

    private static func display(_ cell: [String: String]?) -> String {
        guard let cell else { return "none" }
        return cell.keys.sorted().map { "\($0)=\(cell[$0] ?? "")" }.joined(separator: ",")
    }

    private static func registryPaths(root: URL) -> [String] {
        let normalizedRoot = root.standardizedFileURL
        let directory = normalizedRoot.appending(path: registryDirectory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .map { $0.standardizedFileURL.path.replacingOccurrences(
                of: normalizedRoot.path + "/", with: ""
            ) }
            .sorted()
    }

    private static func loadObject(
        path: String, root: URL, diagnostics: inout [VerificationDiagnostic]
    ) -> [String: Any]? {
        let url = root.appending(path: path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path.hasPrefix(rootPath + "/"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            add(&diagnostics, "AHV-REGISTRY-READ", path, "registry support document is unreadable")
            return nil
        }
        return object
    }

    private static func add(
        _ diagnostics: inout [VerificationDiagnostic], _ code: String,
        _ location: String, _ message: String
    ) {
        diagnostics.append(.init(code: code, location: location, message: message))
    }
}

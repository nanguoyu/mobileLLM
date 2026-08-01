// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum AgentHarnessManifestVerifier {
    private static let requirementIDPattern = "^AH-[A-Z0-9]+(?:-[A-Z0-9]+)+$"
    private static let testIDPattern = "^AHT-[A-Z0-9]+(?:-[A-Z0-9]+)+$"

    public static func verify(_ configuration: VerificationConfiguration) -> VerificationReport {
        var diagnostics: [VerificationDiagnostic] = []
        guard let requirements: RequirementsDocument = decode(
            RequirementsDocument.self, from: configuration.requirementsURL,
            root: configuration.repositoryRoot, label: "requirements", diagnostics: &diagnostics
        ), let tests: TestsDocument = decode(
            TestsDocument.self, from: configuration.testsURL,
            root: configuration.repositoryRoot, label: "tests", diagnostics: &diagnostics
        ), let quarantine: QuarantineDocument = decode(
            QuarantineDocument.self, from: configuration.quarantineURL,
            root: configuration.repositoryRoot, label: "quarantine", diagnostics: &diagnostics
        ) else {
            return VerificationReport(diagnostics: diagnostics)
        }

        validateHeaders(requirements, tests, quarantine, diagnostics: &diagnostics)
        let specLines = validateSpec(requirements.sourceSpecification,
                                     root: configuration.repositoryRoot,
                                     diagnostics: &diagnostics)
        let requirementMap = validateRequirements(requirements.requirements, specLines: specLines,
                                                  mode: configuration.mode,
                                                  diagnostics: &diagnostics)
        let testMap = validateTests(tests.tests, root: configuration.repositoryRoot,
                                    mode: configuration.mode, diagnostics: &diagnostics)
        validateTraceability(requirements: requirementMap, tests: testMap,
                             diagnostics: &diagnostics)
        validateQuarantine(quarantine, requirements: requirementMap, tests: testMap,
                           now: configuration.now, diagnostics: &diagnostics)
        return VerificationReport(diagnostics: diagnostics)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHeaders(
        _ requirements: RequirementsDocument,
        _ tests: TestsDocument,
        _ quarantine: QuarantineDocument,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        for (name, version) in [
            ("requirements", requirements.schemaVersion),
            ("tests", tests.schemaVersion),
            ("quarantine", quarantine.schemaVersion),
        ] where version != 1 {
            add(&diagnostics, "AHV-SCHEMA-VERSION", name,
                "schemaVersion must be 1; found \(version)")
        }
        if requirements.documentID != "AH-REQUIREMENTS-V1" {
            add(&diagnostics, "AHV-DOCUMENT-ID", "requirements.documentID",
                "expected AH-REQUIREMENTS-V1")
        }
        if tests.documentID != "AHT-TESTS-V1" {
            add(&diagnostics, "AHV-DOCUMENT-ID", "tests.documentID", "expected AHT-TESTS-V1")
        }
        if quarantine.documentID != "AH-QUARANTINE-V1" {
            add(&diagnostics, "AHV-DOCUMENT-ID", "quarantine.documentID",
                "expected AH-QUARANTINE-V1")
        }
    }

    private static func validateSpec(
        _ spec: SourceSpecification,
        root: URL,
        diagnostics: inout [VerificationDiagnostic]
    ) -> [String]? {
        guard spec.path == "spec.md", let url = confinedURL(spec.path, root: root),
              let data = try? Data(contentsOf: url) else {
            add(&diagnostics, "AHV-SPEC-PATH", "sourceSpecification.path",
                "path must resolve to readable repository file spec.md")
            return nil
        }
        if !matches(spec.sha256, pattern: "^[a-f0-9]{64}$") {
            add(&diagnostics, "AHV-SPEC-HASH-FORMAT", "sourceSpecification.sha256",
                "SHA-256 must be 64 lowercase hexadecimal characters")
        } else {
            let actual = sha256Hex(of: data)
            if actual != spec.sha256 {
                add(&diagnostics, "AHV-SPEC-HASH-MISMATCH", spec.path,
                    "manifest has \(spec.sha256), actual SHA-256 is \(actual)")
            }
        }
        if parseInstant(spec.capturedAtUTC) == nil {
            add(&diagnostics, "AHV-SPEC-CAPTURE-DATE", "sourceSpecification.capturedAtUTC",
                "capturedAtUTC must be an ISO-8601 timestamp")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            add(&diagnostics, "AHV-SPEC-UTF8", spec.path, "spec must be valid UTF-8")
            return nil
        }
        return text.components(separatedBy: .newlines)
    }

    private static func validateRequirements(
        _ records: [RequirementRecord],
        specLines: [String]?,
        mode: VerificationMode,
        diagnostics: inout [VerificationDiagnostic]
    ) -> [String: RequirementRecord] {
        var result: [String: RequirementRecord] = [:]
        if records.isEmpty { add(&diagnostics, "AHV-REQUIREMENTS-EMPTY", "requirements", "list is empty") }
        for (index, record) in records.enumerated() {
            let fallback = "requirements[\(index)]"
            guard matches(record.id, pattern: requirementIDPattern) else {
                add(&diagnostics, "AHV-REQUIREMENT-ID", fallback,
                    "invalid RequirementID: \(record.id)")
                continue
            }
            if result.updateValue(record, forKey: record.id) != nil {
                add(&diagnostics, "AHV-REQUIREMENT-DUPLICATE", record.id, "RequirementID is duplicated")
            }
            member(record.status, allowed: VerificationVocabulary.requirementStatuses,
                   field: "status", at: record.id, diagnostics: &diagnostics)
            member(record.riskTier, allowed: VerificationVocabulary.risks,
                   field: "riskTier", at: record.id, diagnostics: &diagnostics)
            values(record.platforms, allowed: VerificationVocabulary.platforms,
                   field: "platforms", at: record.id, diagnostics: &diagnostics)
            values(record.verificationTiers, allowed: VerificationVocabulary.tiers,
                   field: "verificationTiers", at: record.id, diagnostics: &diagnostics)
            nonemptyUnique(record.requiredEvidence, field: "requiredEvidence", at: record.id,
                           diagnostics: &diagnostics)
            IDs(record.testIDs, pattern: testIDPattern, kind: "TestID", at: record.id,
                diagnostics: &diagnostics)
            if record.testIDs.isEmpty {
                add(&diagnostics, "AHV-REQUIREMENT-UNMAPPED", record.id,
                    "requirement must map to at least one TestID")
            }
            if record.specAnchors.isEmpty {
                add(&diagnostics, "AHV-SOURCE-ANCHOR", record.id,
                    "requirement must have at least one source anchor")
            } else if let specLines {
                for (anchorIndex, anchor) in record.specAnchors.enumerated() {
                    validate(anchor: anchor, in: specLines,
                             location: "\(record.id).specAnchors[\(anchorIndex)]",
                             diagnostics: &diagnostics)
                }
            }
            if mode == .release, record.status != "active" {
                add(&diagnostics, "AHV-RELEASE-REQUIREMENT-STATUS", record.id,
                    "release requires active; found \(record.status)")
            }
        }
        return result
    }

    private static func validateTests(
        _ records: [TestRecord],
        root: URL,
        mode: VerificationMode,
        diagnostics: inout [VerificationDiagnostic]
    ) -> [String: TestRecord] {
        var result: [String: TestRecord] = [:]
        if records.isEmpty { add(&diagnostics, "AHV-TESTS-EMPTY", "tests", "list is empty") }
        for (index, record) in records.enumerated() {
            let fallback = "tests[\(index)]"
            guard matches(record.id, pattern: testIDPattern) else {
                add(&diagnostics, "AHV-TEST-ID", fallback, "invalid TestID: \(record.id)")
                continue
            }
            if result.updateValue(record, forKey: record.id) != nil {
                add(&diagnostics, "AHV-TEST-DUPLICATE", record.id, "TestID is duplicated")
            }
            member(record.status, allowed: VerificationVocabulary.testStatuses,
                   field: "status", at: record.id, diagnostics: &diagnostics)
            member(record.riskTier, allowed: VerificationVocabulary.risks,
                   field: "riskTier", at: record.id, diagnostics: &diagnostics)
            values(record.platforms, allowed: VerificationVocabulary.platforms,
                   field: "platforms", at: record.id, diagnostics: &diagnostics)
            values(record.verificationTiers, allowed: VerificationVocabulary.tiers,
                   field: "verificationTiers", at: record.id, diagnostics: &diagnostics)
            nonemptyUnique(record.requiredEvidence, field: "requiredEvidence", at: record.id,
                           diagnostics: &diagnostics)
            IDs(record.requirementIDs, pattern: requirementIDPattern, kind: "RequirementID", at: record.id,
                diagnostics: &diagnostics)
            if record.requirementIDs.isEmpty {
                add(&diagnostics, "AHV-TEST-UNMAPPED", record.id,
                    "test must map to at least one RequirementID")
            }
            if Set(record.selectors).count != record.selectors.count {
                add(&diagnostics, "AHV-SELECTOR-DUPLICATE", record.id, "selectors must be unique")
            }
            for selector in record.selectors {
                member(selector.kind, allowed: VerificationVocabulary.selectorKinds,
                       field: "selector.kind", at: record.id, diagnostics: &diagnostics)
            }
            if record.status == "active" {
                if record.selectors.isEmpty {
                    add(&diagnostics, "AHV-ACTIVE-SELECTOR", record.id,
                        "active test requires at least one selector")
                } else {
                    for selector in record.selectors {
                        validateActiveSelector(selector, testID: record.id, root: root,
                                               diagnostics: &diagnostics)
                    }
                }
            }
            if mode == .release, record.status != "active" {
                add(&diagnostics, "AHV-RELEASE-TEST-STATUS", record.id,
                    "release requires active; found \(record.status)")
            }
        }
        return result
    }

    private static func validateTraceability(
        requirements: [String: RequirementRecord],
        tests: [String: TestRecord],
        diagnostics: inout [VerificationDiagnostic]
    ) {
        for requirement in requirements.values.sorted(by: { $0.id < $1.id }) {
            for testID in Set(requirement.testIDs).sorted() {
                guard let test = tests[testID] else {
                    add(&diagnostics, "AHV-UNKNOWN-TEST", requirement.id,
                        "references unknown TestID \(testID)")
                    continue
                }
                if !test.requirementIDs.contains(requirement.id) {
                    add(&diagnostics, "AHV-TRACEABILITY-ASYMMETRIC", requirement.id,
                        "maps to \(testID), but that test does not map back")
                }
                if requirement.status == "active", test.status != "active" {
                    add(&diagnostics, "AHV-ACTIVE-PLANNED-TEST", requirement.id,
                        "active requirement maps to non-active test \(testID)")
                }
                if requirement.status == "retired" || test.status == "retired" {
                    add(&diagnostics, "AHV-RETIRED-LINK", requirement.id,
                        "traceability may not include retired requirement/test \(testID)")
                }
            }
        }
        for test in tests.values.sorted(by: { $0.id < $1.id }) {
            for requirementID in Set(test.requirementIDs).sorted() {
                guard let requirement = requirements[requirementID] else {
                    add(&diagnostics, "AHV-UNKNOWN-REQUIREMENT", test.id,
                        "references unknown RequirementID \(requirementID)")
                    continue
                }
                if !requirement.testIDs.contains(test.id) {
                    add(&diagnostics, "AHV-TRACEABILITY-ASYMMETRIC", test.id,
                        "maps to \(requirementID), but that requirement does not map back")
                }
            }
        }
    }

    private static func validateQuarantine(
        _ document: QuarantineDocument,
        requirements: [String: RequirementRecord],
        tests: [String: TestRecord],
        now: Date,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let policy = document.policy
        if policy.maximumDays != 7 || !policy.forbiddenRiskTiers.contains("P0")
            || !policy.expiredEntryFailsVerification {
            add(&diagnostics, "AHV-QUARANTINE-POLICY", "quarantine.policy",
                "policy must enforce seven days, forbid P0, and fail expired entries")
        }
        var seen: Set<String> = []
        for (index, entry) in document.entries.enumerated() {
            let location = "quarantine.entries[\(index)]"
            if !seen.insert(entry.testID).inserted {
                add(&diagnostics, "AHV-QUARANTINE-DUPLICATE", entry.testID,
                    "test appears more than once")
            }
            guard let test = tests[entry.testID] else {
                add(&diagnostics, "AHV-QUARANTINE-UNKNOWN-TEST", location,
                    "unknown TestID \(entry.testID)")
                continue
            }
            if entry.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || entry.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(&diagnostics, "AHV-QUARANTINE-METADATA", entry.testID,
                    "owner and reason must not be empty")
            }
            IDs(entry.replacementCoverageTestIDs, pattern: testIDPattern, kind: "replacement TestID",
                at: entry.testID, diagnostics: &diagnostics)
            if entry.replacementCoverageTestIDs.isEmpty {
                add(&diagnostics, "AHV-QUARANTINE-REPLACEMENT", entry.testID,
                    "replacement coverage must not be empty")
            }
            guard let created = parseInstant(entry.createdAtUTC),
                  let expires = parseInstant(entry.expiresAtUTC) else {
                add(&diagnostics, "AHV-QUARANTINE-DATE", entry.testID,
                    "createdAtUTC and expiresAtUTC must be ISO-8601 timestamps")
                continue
            }
            let maximum = TimeInterval(policy.maximumDays * 86_400)
            if expires < created || expires.timeIntervalSince(created) > maximum {
                add(&diagnostics, "AHV-QUARANTINE-WINDOW", entry.testID,
                    "quarantine duration must be between zero and \(policy.maximumDays) days")
            }
            if expires < now {
                add(&diagnostics, "AHV-QUARANTINE-EXPIRED", entry.testID,
                    "quarantine expired at \(entry.expiresAtUTC)")
            }
            let mapped = test.requirementIDs.compactMap { requirements[$0] }
            if mapped.contains(where: {
                policy.forbiddenRiskTiers.contains($0.riskTier)
                    || policy.forbiddenAreas.contains($0.area)
            }) {
                add(&diagnostics, "AHV-FORBIDDEN-QUARANTINE", entry.testID,
                    "test covers a risk tier or area forbidden by quarantine policy")
            }
        }
    }

    private static func validate(anchor: SpecAnchor, in lines: [String], location: String,
                                 diagnostics: inout [VerificationDiagnostic]) {
        guard anchor.lineStart >= 1, anchor.lineEnd >= anchor.lineStart,
              anchor.lineEnd <= lines.count else {
            add(&diagnostics, "AHV-SOURCE-RANGE", location,
                "line range \(anchor.lineStart)-\(anchor.lineEnd) is outside spec.md")
            return
        }
        var closest: (section: String, heading: String)?
        if anchor.lineStart > 0 {
            for lineNumber in stride(from: anchor.lineStart, through: 1, by: -1) {
                if let parsed = parseHeading(lines[lineNumber - 1]) {
                    closest = parsed
                    break
                }
            }
        }
        guard let closest, closest.section == anchor.section,
              normalizedHeading(closest.heading) == normalizedHeading(anchor.heading) else {
            add(&diagnostics, "AHV-SOURCE-ANCHOR", location,
                "expected enclosing heading \(anchor.section) \(anchor.heading)")
            return
        }
    }

    private static func parseHeading(_ line: String) -> (section: String, heading: String)? {
        let pattern = #"^\s{0,3}#{1,6}\s+([0-9]+(?:\.[0-9]+)*)\.?(?:\s+)(.+?)\s*#*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let sectionRange = Range(match.range(at: 1), in: line),
              let headingRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[sectionRange]), String(line[headingRange]))
    }

    private static func normalizedHeading(_ heading: String) -> String {
        heading
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateActiveSelector(
        _ selector: TestSelector,
        testID: String,
        root: URL,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        guard VerificationVocabulary.selectorKinds.contains(selector.kind) else { return }
        switch selector.kind {
        case "script":
            guard let url = confinedURL(selector.value, root: root),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                add(&diagnostics, "AHV-ACTIVE-SOURCE-MISSING", testID,
                    "script selector is unreadable: \(selector.value)")
                return
            }
            if !text.contains("TEST-ID: \(testID)") {
                add(&diagnostics, "AHV-ACTIVE-MARKER-MISSING", testID,
                    "script must contain marker 'TEST-ID: \(testID)'")
            }
        case "swift-test", "xctest", "ui-test", "device-scenario":
            guard let symbol = selector.value.split(separator: "/").last.map(String.init),
                  matches(symbol, pattern: "^[A-Za-z_][A-Za-z0-9_]*$") else {
                add(&diagnostics, "AHV-ACTIVE-SYMBOL", testID,
                    "selector must end in a Swift symbol: \(selector.value)")
                return
            }
            let marker = "TEST-ID: \(testID)"
            if !swiftSourceExists(root: root, marker: marker, symbol: symbol) {
                add(&diagnostics, "AHV-ACTIVE-SOURCE-MISSING", testID,
                    "no Swift source contains both '\(marker)' and symbol \(symbol)")
            }
        case "manual-inspection":
            if selector.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(&diagnostics, "AHV-ACTIVE-SELECTOR", testID,
                    "manual inspection selector must be named")
            }
        default: break
        }
    }

    private static func swiftSourceExists(root: URL, marker: String, symbol: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        while let url = enumerator.nextObject() as? URL {
            if [".build", "Vendor", "DerivedData"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(marker), text.contains(symbol) else { continue }
            return true
        }
        return false
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL, root: URL,
                                              label: String,
                                              diagnostics: inout [VerificationDiagnostic]) -> T? {
        guard isConfined(url, to: root), let data = try? Data(contentsOf: url) else {
            add(&diagnostics, "AHV-MANIFEST-MISSING", label,
                "manifest is unreadable or outside repository: \(url.path)")
            return nil
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            add(&diagnostics, "AHV-MANIFEST-DECODE", label,
                "invalid JSON manifest: \(stableDecodingMessage(error))")
            return nil
        }
    }

    private static func member(_ value: String, allowed: Set<String>, field: String, at location: String,
                               diagnostics: inout [VerificationDiagnostic]) {
        if !allowed.contains(value) {
            add(&diagnostics, "AHV-VOCABULARY", "\(location).\(field)",
                "unsupported '\(value)'; allowed: \(allowed.sorted().joined(separator: ", "))")
        }
    }

    private static func values(_ list: [String], allowed: Set<String>, field: String,
                               at location: String, diagnostics: inout [VerificationDiagnostic]) {
        nonemptyUnique(list, field: field, at: location, diagnostics: &diagnostics)
        for value in Set(list).sorted() where !allowed.contains(value) {
            add(&diagnostics, "AHV-VOCABULARY", "\(location).\(field)",
                "unsupported '\(value)'; allowed: \(allowed.sorted().joined(separator: ", "))")
        }
    }

    private static func nonemptyUnique(_ list: [String], field: String, at location: String,
                                       diagnostics: inout [VerificationDiagnostic]) {
        if list.isEmpty {
            add(&diagnostics, "AHV-EVIDENCE-MISSING", "\(location).\(field)",
                "at least one value is required")
        }
        if Set(list).count != list.count {
            add(&diagnostics, "AHV-VALUE-DUPLICATE", "\(location).\(field)",
                "values must be unique")
        }
        for value in list where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(&diagnostics, "AHV-EVIDENCE-MISSING", "\(location).\(field)",
                "values must not be blank")
        }
    }

    private static func IDs(_ list: [String], pattern: String, kind: String, at location: String,
                            diagnostics: inout [VerificationDiagnostic]) {
        if Set(list).count != list.count {
            add(&diagnostics, "AHV-MAPPING-DUPLICATE", location, "mapped \(kind)s must be unique")
        }
        for value in Set(list).sorted() where !matches(value, pattern: pattern) {
            add(&diagnostics, "AHV-MAPPED-ID", location, "invalid mapped \(kind): \(value)")
        }
    }

    private static func confinedURL(_ path: String, root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return nil }
        let url = root.appending(path: path).standardizedFileURL
        return isConfined(url, to: root) ? url : nil
    }

    private static func isConfined(_ url: URL, to root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static func parseInstant(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func stableDecodingMessage(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        switch decoding {
        case .keyNotFound(let key, let context):
            let prefix = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "missing key \(prefix.isEmpty ? "" : prefix + ".")\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return "unknown decoding error"
        }
    }

    private static func add(_ diagnostics: inout [VerificationDiagnostic], _ code: String,
                            _ location: String, _ message: String) {
        diagnostics.append(.init(code: code, location: location, message: message))
    }
}

// SPDX-License-Identifier: MIT

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct XUnitEvidence {
    var status = "missing-evidence"
    var tests = 0
    var failures = 0
    var errors = 0
    var skipped = 0
    var sha256: String?
}

enum XUnitEvidenceParser {
    static func parse(
        _ url: URL,
        diagnostics: inout [CoverageReportDiagnostic]
    ) -> XUnitEvidence {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            diagnostics.append(.init(
                code: "AHV-TEST-EVIDENCE-MISSING", location: url.path,
                message: "xUnit test result is missing or empty"
            ))
            return .init()
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawSupportedRoot else {
            let detail = parser.parserError?.localizedDescription ?? "unsupported xUnit document root"
            diagnostics.append(.init(
                code: "AHV-TEST-EVIDENCE-DECODE", location: url.path,
                message: "xUnit test result is invalid: \(detail)"
            ))
            return .init(sha256: AgentHarnessManifestVerifier.sha256Hex(of: data))
        }
        let evidence = XUnitEvidence(
            status: delegate.tests == 0 ? "empty" : "measured",
            tests: delegate.tests,
            failures: delegate.failures,
            errors: delegate.errors,
            skipped: delegate.skipped,
            sha256: AgentHarnessManifestVerifier.sha256Hex(of: data)
        )
        if evidence.tests == 0 {
            diagnostics.append(.init(
                code: "AHV-TEST-EVIDENCE-EMPTY", location: url.path,
                message: "xUnit result discovered zero test cases"
            ))
        }
        if evidence.failures > 0 || evidence.errors > 0 {
            diagnostics.append(.init(
                code: "AHV-TEST-EVIDENCE-FAILURE", location: url.path,
                message: "xUnit result contains \(evidence.failures) failure(s) and "
                    + "\(evidence.errors) error(s)"
            ))
        }
        if evidence.skipped > 0 {
            diagnostics.append(.init(
                code: "AHV-TEST-EVIDENCE-SKIP", location: url.path,
                message: "xUnit result contains \(evidence.skipped) unexpected skipped test(s)"
            ))
        }
        return evidence
    }
}

private final class Delegate: NSObject, XMLParserDelegate {
    var sawSupportedRoot = false
    var tests = 0
    var failures = 0
    var errors = 0
    var skipped = 0

    private var depth = 0
    private var insideTestCase = false
    private var currentFailure = false
    private var currentError = false
    private var currentSkipped = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if depth == 0, elementName == "testsuite" || elementName == "testsuites" {
            sawSupportedRoot = true
        }
        depth += 1
        if elementName == "testcase" {
            tests += 1
            insideTestCase = true
            currentFailure = false
            currentError = false
            currentSkipped = false
        } else if insideTestCase {
            switch elementName {
            case "failure": currentFailure = true
            case "error": currentError = true
            case "skipped": currentSkipped = true
            default: break
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "testcase", insideTestCase {
            if currentFailure { failures += 1 }
            if currentError { errors += 1 }
            if currentSkipped { skipped += 1 }
            insideTestCase = false
        }
        depth -= 1
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }
}

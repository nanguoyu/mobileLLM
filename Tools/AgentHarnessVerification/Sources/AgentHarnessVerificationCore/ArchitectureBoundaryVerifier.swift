// SPDX-License-Identifier: MIT

import Foundation

/// Enforces the deliberately narrow package and feature boundary of the first Agent Harness release.
///
/// The verifier parses a small, deterministic Swift lexical surface. It never executes Package.swift and it scans
/// production source roots only, so examples, fixtures, and test doubles cannot accidentally satisfy or violate a
/// production gate.
enum ArchitectureBoundaryVerifier {
    private struct PackageRule {
        let name: String
        let allowedPackageDependencies: Set<String>
        let allowedLocalImports: Set<String>
    }

    private static let packageRules = [
        PackageRule(
            name: "AgentContracts",
            allowedPackageDependencies: [],
            allowedLocalImports: []
        ),
        PackageRule(
            name: "AgentSandboxAPI",
            allowedPackageDependencies: ["AgentContracts"],
            allowedLocalImports: ["AgentContracts"]
        ),
        PackageRule(
            name: "AgentRuntime",
            allowedPackageDependencies: ["AgentContracts", "AgentSandboxAPI", "LLMCore", "AppRuntime"],
            allowedLocalImports: ["AgentContracts", "AgentSandboxAPI", "LLMCore", "AppRuntime"]
        ),
    ]

    private static let forbiddenFrameworkImports: Set<String> = [
        "AppKit", "ARKit", "AVFoundation", "CoreBluetooth", "CoreLocation", "EventKit",
        "FoundationModels", "HealthKit", "Metal", "MetalKit", "MetalPerformanceShaders",
        "MobileLLMUI", "NaturalLanguage", "Photos", "RealityKit", "SwiftUI", "UIKit",
        "UserNotifications", "Vision", "WatchKit", "WebKit",
    ]

    static func verify(root: URL, diagnostics: inout [VerificationDiagnostic]) {
        let root = root.standardizedFileURL
        let localModules = discoverLocalPackageNames(root: root)
        for rule in packageRules {
            verifyPackage(rule, root: root, localModules: localModules, diagnostics: &diagnostics)
        }
        verifyDeferredFeatures(root: root, diagnostics: &diagnostics)
    }

    private static func verifyPackage(
        _ rule: PackageRule,
        root: URL,
        localModules: Set<String>,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let packagePath = "Packages/\(rule.name)"
        let packageURL = root.appending(path: packagePath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
            // AgentSandboxAPI and AgentRuntime are planned packages. Absence is not implementation evidence and is
            // intentionally not an error. AgentContracts follows the same rule until its package directory appears.
            return
        }
        guard isDirectory.boolValue else {
            add(&diagnostics, "AHV-ARCH-PACKAGE", packagePath, "package path must be a directory")
            return
        }

        let manifestPath = "\(packagePath)/Package.swift"
        guard let manifest = readText(root: root, relativePath: manifestPath) else {
            add(&diagnostics, "AHV-ARCH-PACKAGE", manifestPath,
                "an introduced Agent Harness package must have a readable Package.swift")
            return
        }
        let tokens = SwiftLexer.lex(manifest)
        validateDeclaredPackages(tokens, rule: rule, packageURL: packageURL, root: root,
                                 path: manifestPath, diagnostics: &diagnostics)
        validateProductionTargetDependencies(tokens, rule: rule, path: manifestPath,
                                             diagnostics: &diagnostics)

        let sourcesPath = "\(packagePath)/Sources/\(rule.name)"
        let sources = swiftFiles(root: root, relativeDirectory: sourcesPath)
        if sources.isEmpty {
            add(&diagnostics, "AHV-ARCH-SOURCES", sourcesPath,
                "an introduced Agent Harness package must contain production Swift sources")
        }
        for path in sources {
            guard let source = readText(root: root, relativePath: path) else {
                add(&diagnostics, "AHV-ARCH-SOURCE-READ", path, "production source is unreadable")
                continue
            }
            for imported in importedModules(from: SwiftLexer.lex(source)) {
                let module = imported.name
                let forbiddenLocal = localModules.contains(module)
                    && module != rule.name
                    && !rule.allowedLocalImports.contains(module)
                if forbiddenLocal || forbiddenFramework(module, package: rule.name) {
                    add(&diagnostics, "AHV-ARCH-IMPORT", "\(path):\(imported.line)",
                        "\(rule.name) may not import \(module)")
                }
            }
        }
    }

    private static func validateDeclaredPackages(
        _ tokens: [SwiftToken],
        rule: PackageRule,
        packageURL: URL,
        root: URL,
        path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        for invocation in invocations(named: "package", tokens: tokens) {
            if let dependencyPath = stringArgument(named: "path", in: invocation.body) {
                let resolved = URL(fileURLWithPath: dependencyPath, relativeTo: packageURL)
                    .standardizedFileURL
                let dependency = resolved.lastPathComponent
                let expected = root.appending(path: "Packages/\(dependency)").standardizedFileURL
                if !rule.allowedPackageDependencies.contains(dependency) || resolved != expected {
                    add(&diagnostics, "AHV-ARCH-PACKAGE-DEPENDENCY", "\(path):\(invocation.line)",
                        "\(rule.name) may not declare local package dependency \(dependencyPath)")
                }
            } else if stringArgument(named: "url", in: invocation.body) != nil {
                add(&diagnostics, "AHV-ARCH-PACKAGE-DEPENDENCY", "\(path):\(invocation.line)",
                    "\(rule.name) may not declare remote package dependencies")
            } else {
                add(&diagnostics, "AHV-ARCH-PACKAGE-DEPENDENCY", "\(path):\(invocation.line)",
                    "package dependency must use a statically verifiable repository-local path")
            }
        }
    }

    private static func validateProductionTargetDependencies(
        _ tokens: [SwiftToken],
        rule: PackageRule,
        path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let targets = invocations(named: "target", tokens: tokens).filter {
            stringArgument(named: "name", in: $0.body) == rule.name
        }
        guard targets.count == 1, let target = targets.first else {
            add(&diagnostics, "AHV-ARCH-TARGET", path,
                "Package.swift must declare exactly one production target named \(rule.name)")
            return
        }
        let dependencies = targetDependencyNames(in: target.body)
        for dependency in dependencies.sorted() where !rule.allowedPackageDependencies.contains(dependency) {
            add(&diagnostics, "AHV-ARCH-TARGET-DEPENDENCY", "\(path):\(target.line)",
                "\(rule.name) target may not depend on \(dependency)")
        }
    }

    private static func forbiddenFramework(_ module: String, package: String) -> Bool {
        if forbiddenFrameworkImports.contains(module) { return true }
        let lowered = module.lowercased()
        if lowered.hasPrefix("mlx") || lowered.contains("llama") || module.hasPrefix("LLMEngine") {
            return true
        }
        if lowered.contains("sandbox") && module != "AgentSandboxAPI" {
            return true
        }
        if package == "AgentContracts" && ["LLMCore", "AppRuntime", "AgentSandboxAPI", "AgentRuntime"]
            .contains(module) {
            return true
        }
        return false
    }

    private static func verifyDeferredFeatures(
        root: URL,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        for path in productionSwiftFiles(root: root) {
            guard let source = readText(root: root, relativePath: path) else {
                add(&diagnostics, "AHV-ARCH-SOURCE-READ", path, "production source is unreadable")
                continue
            }
            let tokens = SwiftLexer.lex(source)
            inspectDeclarations(tokens, path: path, diagnostics: &diagnostics)
            inspectForbiddenExecution(tokens, path: path, diagnostics: &diagnostics)
        }
    }

    private static func inspectDeclarations(
        _ tokens: [SwiftToken],
        path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let concreteKinds: Set<String> = ["actor", "class", "enum", "struct"]
        for index in tokens.indices {
            guard case .identifier(let kind) = tokens[index].kind else { continue }
            if concreteKinds.contains(kind), index + 1 < tokens.count,
               case .identifier(let name) = tokens[index + 1].kind {
                let lowered = name.lowercased()
                let conformances = declarationConformances(tokens, startingAt: index + 2)

                if (lowered.contains("workflow") && lowered.contains("interpreter"))
                    || lowered == "workflowtable"
                    || (lowered.contains("dag") && lowered.contains("scheduler"))
                    || lowered == "dependencyscheduler" {
                    add(&diagnostics, "AHV-DEFERRED-WORKFLOW", "\(path):\(tokens[index].line)",
                        "first release may not implement \(name)")
                }
                if conformances.contains("AgentSandboxProvider") || placeholderSandboxName(lowered) {
                    add(&diagnostics, "AHV-DEFERRED-SANDBOX", "\(path):\(tokens[index].line)",
                        "open-source production sources may not implement a sandbox provider or substitute")
                }
                if onlineProviderImplementationName(lowered) {
                    add(&diagnostics, "AHV-DEFERRED-ONLINE-MODEL", "\(path):\(tokens[index].line)",
                        "first release may not implement online model provider \(name)")
                }
                if shellImplementationName(lowered) {
                    add(&diagnostics, "AHV-DEFERRED-SHELL", "\(path):\(tokens[index].line)",
                        "production sources may not expose arbitrary shell/process execution")
                }
            }

            if kind == "extension", index + 1 < tokens.count,
               case .identifier = tokens[index + 1].kind {
                let conformances = declarationConformances(tokens, startingAt: index + 2)
                if conformances.contains("AgentSandboxProvider") {
                    add(&diagnostics, "AHV-DEFERRED-SANDBOX", "\(path):\(tokens[index].line)",
                        "open-source production sources may not implement AgentSandboxProvider")
                }
            }

            if kind == "func", index + 1 < tokens.count,
               case .identifier(let name) = tokens[index + 1].kind {
                let lowered = name.lowercased()
                if (lowered.contains("workflow") && lowered.contains("interpret"))
                    || (lowered.contains("dag") && lowered.contains("schedul")) {
                    add(&diagnostics, "AHV-DEFERRED-WORKFLOW", "\(path):\(tokens[index].line)",
                        "first release may not implement workflow interpretation or DAG scheduling")
                }
                if lowered.contains("executeshell") || lowered.contains("runshell")
                    || lowered.contains("spawnprocess") {
                    add(&diagnostics, "AHV-DEFERRED-SHELL", "\(path):\(tokens[index].line)",
                        "production sources may not expose arbitrary shell/process execution")
                }
            }
        }
    }

    private static func inspectForbiddenExecution(
        _ tokens: [SwiftToken],
        path: String,
        diagnostics: inout [VerificationDiagnostic]
    ) {
        let processSymbols: Set<String> = [
            "NSTask", "Process", "execl", "execlp", "execv", "execve", "execvp", "execvpe",
            "fork", "popen", "posix_spawn", "posix_spawnp",
        ]
        var reportedLines: Set<Int> = []
        for index in tokens.indices {
            guard case .identifier(let name) = tokens[index].kind else { continue }
            let nextIsCall = index + 1 < tokens.count && tokens[index + 1].isPunctuation("(")
            let previousIsMemberAccess = index > 0 && tokens[index - 1].isPunctuation(".")
            let forbidden = processSymbols.contains(name)
                || (name == "system" && nextIsCall && !previousIsMemberAccess)
            if forbidden, reportedLines.insert(tokens[index].line).inserted {
                add(&diagnostics, "AHV-DEFERRED-SHELL", "\(path):\(tokens[index].line)",
                    "production sources may not reference process or shell entry point \(name)")
            }
        }
    }

    private static func placeholderSandboxName(_ name: String) -> Bool {
        guard name.contains("sandbox") else { return false }
        return ["fake", "mock", "noop", "placeholder", "stub"].contains { name.contains($0) }
    }

    private static func onlineProviderImplementationName(_ name: String) -> Bool {
        let onlineMarker = ["anthropic", "cloud", "gemini", "online", "openai", "remote"]
            .contains { name.contains($0) }
        let implementationMarker = name.contains("provider") || name.contains("client")
        let valueOnlySuffix = ["capability", "configuration", "descriptor", "error", "id", "policy",
                               "request", "response"].contains { name.hasSuffix($0) }
        return onlineMarker && implementationMarker && !valueOnlySuffix
    }

    private static func shellImplementationName(_ name: String) -> Bool {
        name.contains("shell") && (name.contains("executor") || name.contains("runner"))
    }

    private static func declarationConformances(
        _ tokens: [SwiftToken],
        startingAt start: Int
    ) -> Set<String> {
        var names: Set<String> = []
        var sawColon = false
        var angleDepth = 0
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token.isPunctuation("{") && angleDepth == 0 { break }
            if token.isPunctuation(":") && angleDepth == 0 {
                sawColon = true
            } else if token.isPunctuation("<") {
                angleDepth += 1
            } else if token.isPunctuation(">"), angleDepth > 0 {
                angleDepth -= 1
            } else if sawColon, case .identifier(let name) = token.kind,
                      name != "where" {
                names.insert(name)
            }
            index += 1
        }
        return names
    }

    private static func importedModules(from tokens: [SwiftToken]) -> [(name: String, line: Int)] {
        var result: [(String, Int)] = []
        let declarationKinds: Set<String> = ["class", "enum", "func", "let", "protocol", "struct",
                                             "typealias", "var"]
        for index in tokens.indices {
            guard tokens[index].identifier == "import" else { continue }
            var moduleIndex = index + 1
            if moduleIndex < tokens.count, let name = tokens[moduleIndex].identifier,
               declarationKinds.contains(name) {
                moduleIndex += 1
            }
            if moduleIndex < tokens.count, let module = tokens[moduleIndex].identifier {
                result.append((module, tokens[index].line))
            }
        }
        return result
    }

    private struct Invocation {
        let body: ArraySlice<SwiftToken>
        let line: Int
    }

    private static func invocations(named name: String, tokens: [SwiftToken]) -> [Invocation] {
        var result: [Invocation] = []
        var index = 0
        while index + 2 < tokens.count {
            guard tokens[index].isPunctuation("."), tokens[index + 1].identifier == name,
                  tokens[index + 2].isPunctuation("("),
                  let end = matchingDelimiter(in: tokens, from: index + 2, open: "(", close: ")") else {
                index += 1
                continue
            }
            result.append(.init(body: tokens[(index + 3)..<end], line: tokens[index + 1].line))
            index = end + 1
        }
        return result
    }

    private static func stringArgument(named name: String,
                                       in tokens: ArraySlice<SwiftToken>) -> String? {
        let values = Array(tokens)
        for index in values.indices where values[index].identifier == name {
            guard index + 2 < values.count, values[index + 1].isPunctuation(":"),
                  case .string(let value) = values[index + 2].kind else { continue }
            return value
        }
        return nil
    }

    private static func targetDependencyNames(in body: ArraySlice<SwiftToken>) -> Set<String> {
        let tokens = Array(body)
        guard let label = tokens.indices.first(where: { tokens[$0].identifier == "dependencies" }),
              label + 2 < tokens.count, tokens[label + 1].isPunctuation(":"),
              tokens[label + 2].isPunctuation("["),
              let end = matchingDelimiter(in: tokens, from: label + 2, open: "[", close: "]") else {
            return []
        }

        var result: Set<String> = []
        var index = label + 3
        while index < end {
            if case .string(let value) = tokens[index].kind {
                result.insert(value)
                index += 1
                continue
            }
            if tokens[index].isPunctuation("."), index + 2 < end,
               let invocationName = tokens[index + 1].identifier,
               ["byName", "product", "target"].contains(invocationName),
               tokens[index + 2].isPunctuation("("),
               let invocationEnd = matchingDelimiter(in: tokens, from: index + 2,
                                                     open: "(", close: ")") {
                let invocationBody = tokens[(index + 3)..<invocationEnd]
                if let value = stringArgument(named: "name", in: invocationBody) {
                    result.insert(value)
                }
                index = invocationEnd + 1
                continue
            }
            index += 1
        }
        return result
    }

    private static func matchingDelimiter(
        in tokens: [SwiftToken],
        from start: Int,
        open: Character,
        close: Character
    ) -> Int? {
        guard start < tokens.count, tokens[start].isPunctuation(open) else { return nil }
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index].isPunctuation(open) { depth += 1 }
            if tokens[index].isPunctuation(close) {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func discoverLocalPackageNames(root: URL) -> Set<String> {
        let packages = root.appending(path: "Packages", directoryHint: .isDirectory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: packages, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path)
            else { return nil }
            return url.lastPathComponent
        })
    }

    private static func productionSwiftFiles(root: URL) -> [String] {
        var files = swiftFiles(root: root, relativeDirectory: "App")
        let packagesURL = root.appending(path: "Packages", directoryHint: .isDirectory)
        if let packages = try? FileManager.default.contentsOfDirectory(
            at: packagesURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for package in packages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                files.append(contentsOf: swiftFiles(
                    root: root,
                    relativeDirectory: "Packages/\(package.lastPathComponent)/Sources"
                ))
            }
        }
        return Array(Set(files)).sorted()
    }

    private static func swiftFiles(root: URL, relativeDirectory: String) -> [String] {
        let directory = root.appending(path: relativeDirectory, directoryHint: .isDirectory)
        guard isConfined(directory, to: root), let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true,
               [".build", "DerivedData", "Vendor"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "swift", isConfined(url, to: root)
            else { continue }
            result.append(relativePath(of: url, root: root))
        }
        return result.sorted()
    }

    private static func readText(root: URL, relativePath: String) -> String? {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            return nil
        }
        let url = root.appending(path: relativePath).standardizedFileURL
        guard isConfined(url, to: root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func isConfined(_ url: URL, to root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func add(
        _ diagnostics: inout [VerificationDiagnostic],
        _ code: String,
        _ location: String,
        _ message: String
    ) {
        diagnostics.append(.init(code: code, location: location, message: message))
    }
}

private struct SwiftToken {
    enum Kind {
        case identifier(String)
        case punctuation(Character)
        case string(String)
    }

    let kind: Kind
    let line: Int

    var identifier: String? {
        guard case .identifier(let value) = kind else { return nil }
        return value
    }

    func isPunctuation(_ value: Character) -> Bool {
        guard case .punctuation(let token) = kind else { return false }
        return token == value
    }
}

private enum SwiftLexer {
    static func lex(_ source: String) -> [SwiftToken] {
        let characters = Array(source)
        var tokens: [SwiftToken] = []
        var index = 0
        var line = 1
        while index < characters.count {
            let character = characters[index]
            if character == "\n" {
                line += 1
                index += 1
                continue
            }
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                index += 2
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index = skipBlockComment(characters, from: index, line: &line)
                continue
            }
            if let stringStart = rawStringStart(characters, at: index) {
                let parsed = readString(characters, from: index, hashCount: stringStart.hashCount,
                                        multiline: stringStart.multiline, line: &line)
                tokens.append(.init(kind: .string(parsed.value), line: parsed.startLine))
                index = parsed.end
                continue
            }
            if character == "_" || character.isLetter {
                let start = index
                index += 1
                while index < characters.count,
                      characters[index] == "_" || characters[index].isLetter
                        || characters[index].isNumber {
                    index += 1
                }
                tokens.append(.init(kind: .identifier(String(characters[start..<index])), line: line))
                continue
            }
            tokens.append(.init(kind: .punctuation(character), line: line))
            index += 1
        }
        return tokens
    }

    private static func skipBlockComment(
        _ characters: [Character],
        from start: Int,
        line: inout Int
    ) -> Int {
        var index = start + 2
        var depth = 1
        while index < characters.count, depth > 0 {
            if characters[index] == "\n" { line += 1 }
            if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "*" {
                depth += 1
                index += 2
            } else if index + 1 < characters.count, characters[index] == "*", characters[index + 1] == "/" {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func rawStringStart(
        _ characters: [Character],
        at start: Int
    ) -> (hashCount: Int, multiline: Bool)? {
        var quote = start
        while quote < characters.count, characters[quote] == "#" { quote += 1 }
        guard quote < characters.count, characters[quote] == "\"" else { return nil }
        let multiline = quote + 2 < characters.count
            && characters[quote + 1] == "\"" && characters[quote + 2] == "\""
        return (quote - start, multiline)
    }

    private static func readString(
        _ characters: [Character],
        from start: Int,
        hashCount: Int,
        multiline: Bool,
        line: inout Int
    ) -> (value: String, startLine: Int, end: Int) {
        let startLine = line
        let quote = start + hashCount
        let openingWidth = multiline ? 3 : 1
        var index = quote + openingWidth
        let contentStart = index
        while index < characters.count {
            if characters[index] == "\n" { line += 1 }
            let hasQuotes: Bool
            if multiline {
                hasQuotes = index + 2 < characters.count && characters[index] == "\""
                    && characters[index + 1] == "\"" && characters[index + 2] == "\""
            } else {
                hasQuotes = characters[index] == "\""
                    && (hashCount > 0 || !isEscaped(characters, at: index))
            }
            if hasQuotes {
                let quoteWidth = multiline ? 3 : 1
                let hashStart = index + quoteWidth
                let hashesMatch = hashStart + hashCount <= characters.count
                    && characters[hashStart..<(hashStart + hashCount)].allSatisfy { $0 == "#" }
                if hashesMatch {
                    let value = String(characters[contentStart..<index])
                    return (value, startLine, hashStart + hashCount)
                }
            }
            index += 1
        }
        return (String(characters[contentStart..<characters.count]), startLine, characters.count)
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var backslashes = 0
        var cursor = index - 1
        while characters[cursor] == "\\" {
            backslashes += 1
            guard cursor > 0 else { break }
            cursor -= 1
        }
        return backslashes.isMultiple(of: 2) == false
    }
}

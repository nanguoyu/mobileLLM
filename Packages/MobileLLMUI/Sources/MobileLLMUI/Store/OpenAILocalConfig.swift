// SPDX-License-Identifier: MIT

import Foundation

/// One OpenAI-compatible service configuration the developer keeps ON THE MAC, outside the repository
/// (`~/.mobilellm/openai.json`, chmod 600). The macOS DEBUG app reads it directly; simulator and
/// physical-device UI tests have the test runner read it and inject the values through launch
/// environment variables, which the DEBUG app then seeds into its own Keychain.
public struct OpenAILocalConfig: Codable, Sendable, Equatable {
    public var apiKey: String
    public var baseURL: String
    public var model: String?

    public init(apiKey: String, baseURL: String, model: String? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }
}

public enum OpenAILocalConfigLoader {
    public static let directoryName = ".mobilellm"
    public static let fileName = "openai.json"

    /// The Mac-side default location; nil on iOS where the sandbox never contains the developer file.
    public static var defaultURL: URL? {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)
        #else
        return nil
        #endif
    }

    public static func load(from url: URL? = nil) throws -> OpenAILocalConfig {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OpenAILocalConfig.self, from: data)
    }

    /// macOS-only convenience: read the developer's file if present; iOS always returns nil (tests
    /// inject through environment variables instead).
    public static func loadDefault() -> OpenAILocalConfig? {
        guard let url = defaultURL else { return nil }
        return try? load(from: url)
    }

    /// Environment overrides win over the file so CI and one-off runs never need to edit the file.
    public static func applyEnvironment(
        _ environment: [String: String],
        to config: inout OpenAILocalConfig
    ) {
        if let key = environment[OpenAIKeyEnvironment.variableName], !key.isEmpty {
            config.apiKey = key
        }
        if let raw = environment[OpenAIKeyEnvironment.baseURLVariableName],
           let baseURL = OpenAIServiceConfiguration.normalizedBaseURL(raw)
        {
            config.baseURL = baseURL
        }
        if let model = environment[OpenAIKeyEnvironment.modelVariableName], !model.isEmpty {
            config.model = model
        }
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The community-skill IMPORT pipeline (SKILL.md over the network): fetch → status-gate → UTF-8 decode →
/// parse → create. Only the pure `parse()` / `candidateURLs()` halves were tested before; the actual fetch
/// flow lived inside a SwiftUI view using `URLSession.shared` with no seam. Driven here through the
/// (strictly additive) `SkillIO.fetchFirstParseable(from:session:)` seam over a `URLProtocol` stub, so the
/// real networking + persistence run end-to-end without hitting GitHub.
final class SkillImportPipelineTests: XCTestCase {

    // MARK: URLProtocol stub

    /// A `URLProtocol` that answers a per-URL table (status + body). Registered on an ephemeral session so
    /// the import fetch is fully offline + deterministic.
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var table: [String: (status: Int, body: Data)] = [:]

        static func install(_ t: [String: (status: Int, body: Data)]) {
            lock.lock(); table = t; lock.unlock()
        }
        private static func entry(for url: URL) -> (status: Int, body: Data)? {
            lock.lock(); defer { lock.unlock() }; return table[url.absoluteString]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            guard let stub = Self.entry(for: url) else {
                // No stub → simulate an unreachable host (the fetch treats this candidate as a miss).
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
            }
            let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func stubbedSession(_ table: [String: (status: Int, body: Data)]) -> URLSession {
        StubURLProtocol.install(table)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static let validSkillMD = """
    ---
    name: Weather Bot
    description: Gives concise forecasts
    ---

    Always give a concise forecast for the requested city.
    """

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "skill-import-\(UUID().uuidString)")
    }

    // MARK: - fetch → parse → create → persist (happy path)

    /// A GitHub repo URL resolves to its raw SKILL.md, fetches + parses, and the created skill persists to
    /// disk so a fresh store reads it back.
    @MainActor
    func testImportFromGithubFetchesParsesAndPersists() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // github.com/acme/weather → https://raw.githubusercontent.com/acme/weather/main/SKILL.md
        let session = stubbedSession([
            "https://raw.githubusercontent.com/acme/weather/main/SKILL.md": (200, Data(Self.validSkillMD.utf8)),
        ])

        let parsed = await SkillIO.fetchFirstParseable(from: "github.com/acme/weather", session: session)
        let p = try XCTUnwrap(parsed, "the github URL resolves to raw SKILL.md, fetches, and parses")
        XCTAssertEqual(p.name, "Weather Bot")
        XCTAssertEqual(p.summary, "Gives concise forecasts")
        XCTAssertTrue(p.instructions.contains("concise forecast"))

        // The import 'Add' step through the real store (matching SkillImportView.add()).
        let fileURL = dir.appending(component: "skills.json")
        let store = SkillStore(fileURL: fileURL)
        await store.load()   // seed built-ins first (matches the launched app) so reloads never re-seed
        let created = store.create(name: p.name, emoji: "📦", summary: p.summary, instructions: p.instructions)

        // A fresh store at the same file reads the imported skill back.
        let reloaded = try await pollForSkill(fileURL: fileURL, id: created.id)
        XCTAssertEqual(reloaded.name, "Weather Bot")
        XCTAssertEqual(reloaded.instructions, p.instructions, "the imported instructions persist verbatim")
        XCTAssertFalse(reloaded.isBuiltIn, "an imported skill is a custom skill")
    }

    /// A direct .md link is fetched as-is (the `candidateURLs` .md branch, driven through the real fetch).
    func testImportFromDirectMdURL() async throws {
        let session = stubbedSession([
            "https://example.com/skills/forecast/SKILL.md": (200, Data(Self.validSkillMD.utf8)),
        ])
        let parsed = await SkillIO.fetchFirstParseable(from: "https://example.com/skills/forecast/SKILL.md",
                                                       session: session)
        XCTAssertEqual(parsed?.name, "Weather Bot")
    }

    // MARK: - Error paths (each yields nil → the view surfaces the "couldn't find" message)

    func testNon2xxStatusYieldsNoSkill() async throws {
        let session = stubbedSession([
            "https://raw.githubusercontent.com/acme/missing/main/SKILL.md": (404, Data("Not Found".utf8)),
        ])
        let parsed = await SkillIO.fetchFirstParseable(from: "github.com/acme/missing", session: session)
        XCTAssertNil(parsed, "a 404 candidate is rejected by the status gate")
    }

    func testUnparseableBodyYieldsNoSkill() async throws {
        // A GitHub Pages webhost base → https://example.com/skill/SKILL.md; body is 200 but not SKILL.md.
        let session = stubbedSession([
            "https://example.com/skill/SKILL.md": (200, Data("just some prose, no frontmatter".utf8)),
        ])
        let parsed = await SkillIO.fetchFirstParseable(from: "example.com/skill", session: session)
        XCTAssertNil(parsed, "a 200 body that isn't SKILL.md parses to nothing")
    }

    func testNonUTF8BodyYieldsNoSkill() async throws {
        let session = stubbedSession([
            "https://example.com/binary/SKILL.md": (200, Data([0xFF, 0xFE, 0xFF, 0x00, 0xFF])),
        ])
        let parsed = await SkillIO.fetchFirstParseable(from: "example.com/binary", session: session)
        XCTAssertNil(parsed, "a body that isn't valid UTF-8 is skipped by the decode guard")
    }

    func testUnreachableHostYieldsNoSkill() async throws {
        let session = stubbedSession([:])   // no stub for the candidate → connection fails
        let parsed = await SkillIO.fetchFirstParseable(from: "github.com/acme/offline", session: session)
        XCTAssertNil(parsed, "a network failure on the only candidate yields no skill (try? swallows the error)")
    }

    // MARK: - Helper

    @MainActor
    private func pollForSkill(fileURL: URL, id: UUID, timeout: TimeInterval = 2) async throws -> Skill {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fresh = SkillStore(fileURL: fileURL)
            await fresh.load()
            if let s = fresh.skill(id: id) { return s }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let fresh = SkillStore(fileURL: fileURL)
        await fresh.load()
        return try XCTUnwrap(fresh.skill(id: id), "the imported skill never landed on disk")
    }
}

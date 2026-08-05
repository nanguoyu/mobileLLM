// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// Spec §20 "Project": project tags are pure, many-to-many grouping of conversations. Old records
/// without the field must decode unchanged, tags normalize (trim/dedupe/sort), and the picker/filter
/// share one source of truth (`allProjectTags`).
@MainActor
final class ProjectTagsTests: XCTestCase {

    private func makeStore() -> (ChatStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-project-tags-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "project-tags-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings,
                             activeModel: LoadedModel(model: LLMCatalog.bonsai8b,
                                                      variant: LLMCatalog.bonsai8b.defaultVariantValue))
        return (chat, dir)
    }

    func testConversationProjectTagsRoundTripAndLegacyDecode() throws {
        let convo = Conversation(modelID: "test", variantID: "v", projectTags: ["Work", "Home"])
        let data = try JSONEncoder().encode(convo)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.projectTagList, ["Work", "Home"])

        // A legacy record written before projectTags existed must decode with an empty tag list.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old","createdAt":0,"updatedAt":0,
         "modelID":"m","variantID":"v","messages":[],"pinned":false}
        """
        let legacyDecoded = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertEqual(legacyDecoded.projectTagList, [])
        XCTAssertNil(legacyDecoded.projectTags)
    }

    func testSetProjectTagsNormalizesTrimDedupeAndSort() throws {
        let (chat, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let convo = try XCTUnwrap(chat.newConversation())

        chat.setProjectTags(["  Alpha ", "beta", "alpha", ""], for: convo.id)
        XCTAssertEqual(chat.projectTags(for: convo.id), ["Alpha", "beta"])
        XCTAssertEqual(chat.activeConversation?.projectTagList, ["Alpha", "beta"])
    }

    func testToggleAndAllTagsAreSharedAcrossConversations() throws {
        let (chat, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try XCTUnwrap(chat.newConversation())
        // newConversation() deliberately reuses an empty thread, so build a distinct second one with
        // its own message (the production path always has content by the time tags are assigned).
        let second = Conversation(
            modelID: "test",
            variantID: "v",
            messages: [Message(role: .user, answer: "second thread")]
        )
        chat.conversations.insert(second, at: 0)
        XCTAssertNotEqual(first.id, second.id)

        chat.toggleProjectTag("Work", on: first.id)
        chat.toggleProjectTag("Home", on: first.id)
        chat.toggleProjectTag("work", on: second.id)

        XCTAssertEqual(chat.projectTags(for: first.id), ["Home", "Work"])
        XCTAssertEqual(chat.projectTags(for: second.id), ["Work"])
        XCTAssertEqual(chat.allProjectTags, ["Home", "Work"])

        // Toggling the same tag again removes it.
        chat.toggleProjectTag("Work", on: first.id)
        XCTAssertEqual(chat.projectTags(for: first.id), ["Home"])
        XCTAssertEqual(chat.allProjectTags, ["Home", "Work"])
    }
}

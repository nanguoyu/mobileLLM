// SPDX-License-Identifier: MIT

import XCTest

/// Production-path tests for the two downloaded GGUF models. The class is intentionally serial and each
/// behavior is an independent XCTest: one model-quality failure must not hide the remaining product bugs.
final class PhysicalDeviceFullStackUITests: DeviceE2ETestCase {

    // MARK: Launch / core inference

    @MainActor
    func test01ColdLaunchRestoresIdentityWithoutConversationOrWeights() throws {
        let app = try launchApp()
        XCTAssertTrue(app.navigationBars["Chat"].exists)
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "launch must never reopen the most recent conversation")
        let runtime = diagnosticValue("device-e2e.runtime", in: app)
        XCTAssertTrue(runtime.contains("resident=false"),
                      "launch must not allocate model weights: \(runtime)")
        XCTAssertFalse(runtime.contains("phase=warming"), "launch began generation/loading work: \(runtime)")
        attachDiagnostics(app, name: "cold-launch-no-load")
    }

    @MainActor
    func test02BonsaiExactOutputAndMultiTurnContext() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: false)
        let marker = uniqueMarker("BONSAI_CORE")
        let nonce = "CEDAR-\(Int.random(in: 10_000...99_999))"
        var failures: [String] = []
        var formatEvidence: GenerationEvidence?
        var seedEvidence: GenerationEvidence?
        var recallEvidence: GenerationEvidence?

        // Keep strict formatting independent from context ingestion. The previous combined prompt could
        // not distinguish a harmless formatting refusal from failure to retain the nonce.
        do {
            let evidence = try send(
                marker + "\nReturn this verification phrase exactly as written, with no extra text: "
                    + "ALPHA-BETA-GAMMA",
                model: .bonsai, in: app, assertEvidence: false)
            formatEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: .bonsai)
                .map { "Exact-format turn: \($0)" }
            if evidence.answer != "ALPHA-BETA-GAMMA" {
                failures.append(
                    "Exact-format turn answered \(String(reflecting: evidence.answer)); "
                        + "expected exactly ALPHA-BETA-GAMMA"
                )
            }
            if !evidence.toolActivities.isEmpty {
                failures.append("Exact-format turn invoked tools: \(evidence.toolActivities)")
            }
        } catch {
            failures.append("Exact-format turn did not commit evidence: \(error.localizedDescription)")
        }

        // Confirm that Bonsai parsed the nonce before separately testing whether the next turn retains it.
        do {
            let evidence = try send(
                "Use \(nonce) as the temporary nonce for this conversation. "
                    + "Confirm receipt by replying with only \(nonce).",
                model: .bonsai, in: app, assertEvidence: false)
            seedEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: .bonsai)
                .map { "Context-seed turn: \($0)" }
            if evidence.answer != nonce {
                failures.append(
                    "Context-seed turn answered \(String(reflecting: evidence.answer)); "
                        + "expected exactly \(nonce)"
                )
            }
            if !evidence.toolActivities.isEmpty {
                failures.append("Context-seed turn invoked tools: \(evidence.toolActivities)")
            }
        } catch {
            failures.append("Context-seed turn did not commit evidence: \(error.localizedDescription)")
        }

        do {
            let evidence = try send(
                "What temporary nonce was established in the immediately preceding turn? "
                    + "Reply with only that nonce.",
                model: .bonsai, in: app, assertEvidence: false)
            recallEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: .bonsai)
                .map { "Context-recall turn: \($0)" }
            if evidence.answer != nonce {
                failures.append(
                    "Context-recall turn answered \(String(reflecting: evidence.answer)); "
                        + "expected exactly \(nonce)"
                )
            }
            if !evidence.toolActivities.isEmpty {
                failures.append("Context-recall turn invoked tools: \(evidence.toolActivities)")
            }
        } catch {
            failures.append("Context-recall turn did not commit evidence: \(error.localizedDescription)")
        }

        let summary = XCTAttachment(string: """
        expected_format=ALPHA-BETA-GAMMA
        format_answer=\(formatEvidence?.answer ?? "<no evidence>")
        expected_nonce=\(nonce)
        seed_answer=\(seedEvidence?.answer ?? "<no evidence>")
        recall_answer=\(recallEvidence?.answer ?? "<no evidence>")
        format_stats=\(formatEvidence?.stats ?? "<no evidence>")
        seed_stats=\(seedEvidence?.stats ?? "<no evidence>")
        recall_stats=\(recallEvidence?.stats ?? "<no evidence>")
        failures=\(failures.isEmpty ? "none" : failures.joined(separator: "\n- "))
        """)
        summary.name = "bonsai-exact-output-and-context"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertTrue(failures.isEmpty,
                      "Bonsai core path had \(failures.count) independent failure(s):\n- "
                          + failures.joined(separator: "\n- "))
    }

    @MainActor
    func test03GemmaExactOutputMultiTurnAndNoThinkingControl() throws {
        // Gemma 4 E2B is catalogued non-thinking; the agent runtime honestly rejects a reasoning
        // request for it, so the no-thinking control test runs with thinking disabled.
        let app = try prepare(.gemma, tools: false, selected: [], thinking: false)
        try openChatOptions(in: app)
        let thinking = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Thinking")
        ).firstMatch
        XCTAssertFalse(thinking.exists,
                       "Gemma 4 E2B is catalogued non-thinking and must not expose a Thinking toggle")
        try dismissChatOptionsSelectingNoSkill(in: app)
        XCTAssertTrue(waitForEnabled(app.textFields["composer.field"], timeout: 10),
                      "composer did not recover after the deterministic menu dismissal")

        let marker = uniqueMarker("GEMMA_CORE")
        let nonce = "MAPLE-\(Int.random(in: 10_000...99_999))"
        let first = try send(
            marker + "\nRemember the nonce \(nonce). Reply with exactly DELTA-ECHO-FOXTROT and nothing else.",
            model: .gemma, in: app)
        let second = try send("Reply with only the nonce from my prior message.", model: .gemma, in: app)
        XCTAssertEqual(first.answer, "DELTA-ECHO-FOXTROT")
        XCTAssertEqual(second.answer, nonce, "Gemma lost immediate multi-turn context")
        XCTAssertNil(first.reasoning, "Non-thinking Gemma emitted a reasoning channel")
    }

    // MARK: Thinking / cancellation

    @MainActor
    func test04BonsaiCollapsedThinkingStaysLiveAndFinishesWithNonzeroDuration() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: true)
        let marker = uniqueMarker("BONSAI_THINK")
        let copies = app.buttons.matching(identifier: "Copy answer").count
        let stats = app.descendants(matching: .any).matching(identifier: "assistant.stats").count
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(
            marker + "\nThink step by step: multiply 123 by 4, and explain each step before the final number."
        )
        app.buttons["Send"].tap()
        let started = Date()

        let live = app.buttons["Thinking…"]
        XCTAssertTrue(live.waitForExistence(timeout: 240), "Bonsai never entered an observable thinking phase")
        live.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["Stop"].exists, "generation finished before live-collapse could be verified")
        XCTAssertTrue(app.buttons["Thinking…"].exists,
                      "collapsing a live thought must keep the header as Thinking…")
        XCTAssertFalse(app.buttons["Thought for 0.0s"].exists,
                       "a manually collapsed live thought was falsely marked complete")

        let evidence = try waitForCommittedGeneration(model: .bonsai, in: app,
                                                       previousCopyCount: copies,
                                                       previousStatsCount: stats,
                                                       startedAt: started)
        let finishedThought = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Thought for ")
        ).lastMatch
        XCTAssertTrue(finishedThought.waitForExistence(timeout: 20), "completed reasoning has no duration")
        XCTAssertNotEqual(finishedThought.label, "Thought for 0.0s")
        XCTAssertFalse(evidence.answer.isEmpty)
    }

    @MainActor
    func test05BonsaiStopCommitsAndNextTurnRecovers() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: true)
        try exerciseStopAndRecovery(.bonsai, in: app)
    }

    @MainActor
    func test06GemmaStopCommitsAndNextTurnRecovers() throws {
        let app = try prepare(.gemma, tools: false, selected: [], thinking: false)
        try exerciseStopAndRecovery(.gemma, in: app)
    }

    // MARK: Tool selection and on-device tools

    @MainActor
    func test07ToolSelectionsAreIndependentAndPersistAcrossRelaunch() throws {
        let app = try launchApp()
        try configureTools(master: true, enabled: ["Calculator"], in: app)
        try relaunch(app)
        try goToSettings(in: app)
        let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose tools")).firstMatch
        XCTAssertTrue(scrollToHittable(choose, in: app.scrollViews.firstMatch))
        choose.tap()
        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 15))
        let scroll = firstHittableScrollView(in: app)
        let expected: [String: Bool] = [
            "Web search": false, "Webpage reader": false, "Wikipedia": false,
            "Calculator": true, "Clock": false, "Memory": false,
        ]
        for (title, on) in expected {
            let toggle = switchStarting(with: title, in: app)
            XCTAssertTrue(scrollToHittable(toggle, in: scroll))
            XCTAssertEqual(switchIsOn(toggle), on, "Persisted tool selection drifted: \(title)")
        }
        let master = switchStarting(with: "Allow selected tools", in: app)
        XCTAssertTrue(scrollToHittable(master, in: scroll, swipingUp: false))
        XCTAssertTrue(switchIsOn(master))
    }

    @MainActor
    func test08BonsaiCalculatorOnly() throws {
        try exerciseCalculator(.bonsai)
    }

    @MainActor
    func test09GemmaCalculatorOnly() throws {
        try exerciseCalculator(.gemma)
    }

    @MainActor
    func test10BonsaiClockOnly() throws {
        try exerciseClock(.bonsai)
    }

    @MainActor
    func test11GemmaClockOnly() throws {
        try exerciseClock(.gemma)
    }

    @MainActor
    func test12BonsaiWebSearchOnly() throws {
        try exerciseWebSearch(.bonsai)
    }

    @MainActor
    func test13GemmaWebSearchOnly() throws {
        try exerciseWebSearch(.gemma)
    }

    @MainActor
    func test14ToolMasterOffDeniesSelectedWebSearch() throws {
        let app = try prepare(.gemma, tools: false, selected: ["Web search"], thinking: false)
        let marker = uniqueMarker("TOOLS_DENY")
        let evidence = try send(
            marker + "\nSearch the web for OpenAI's official website, then give me its title.",
            model: .gemma, in: app)
        XCTAssertTrue(evidence.toolActivities.isEmpty,
                      "master-off turn still received a tool: \(evidence.toolActivities)")
    }

    // MARK: Memory

    @MainActor
    func test15ManualMemoryAddPersistenceAndPreciseDelete() throws {
        let app = try launchApp()
        let code = "ManualOrchid\(Int.random(in: 10_000...99_999))"
        let sentence = "The user has the device-test code \(code)."
        try addManualMemory(sentence, in: app)
        try relaunch(app)
        let row = try openMemoryAndFind(code, in: app)
        XCTAssertEqual(row.label, sentence)
        XCTAssertTrue(row.value as? String == "Added by you · Now"
                      || ((row.value as? String)?.hasPrefix("Added by you ·") == true))
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts["Delete this memory?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(waitUntilGone(row, timeout: 15))
    }

    @MainActor
    func test16BonsaiSavesEnglishMemoryGemmaReadsWithoutTools() throws {
        try exerciseCrossModelMemory(writer: .bonsai, reader: .gemma)
    }

    @MainActor
    func test17GemmaSavesEnglishMemoryBonsaiReadsWithoutTools() throws {
        try exerciseCrossModelMemory(writer: .gemma, reader: .bonsai)
    }

    // MARK: Vision

    @MainActor
    func test18GemmaVisionFixtureAndImageHistoryWithoutTools() throws {
        let app = try launchApp(visionFixture: true)
        XCTAssertTrue(waitForFixtureCount(1, in: app), "deterministic image fixture was not staged")
        try configureTools(master: false, enabled: [], in: app)
        try openNewChat(in: app)
        try activate(.gemma, in: app)
        XCTAssertTrue(app.staticTexts["Attached image"].exists || app.images["Attached image"].exists
                      || app.buttons["Remove attached image"].waitForExistence(timeout: 10))

        let marker = uniqueMarker("GEMMA_VISION")
        let first = try send(
            marker + "\nIdentify only the two colored shapes. Do not mention any number. Reply exactly SHAPES=RED_SQUARE+BLUE_CIRCLE.",
            model: .gemma, in: app, timeout: 720)
        XCTAssertEqual(first.answer, "SHAPES=RED_SQUARE+BLUE_CIRCLE")
        XCTAssertTrue(first.toolActivities.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "You said", "attached image")
        ).firstMatch.exists, "the committed user turn lost its image attachment")

        // The first answer intentionally omitted the number, so this can succeed only if the persisted
        // image bytes are replayed to the vision engine on the follow-up turn.
        let followup = try send("What four-digit number is printed beneath the shapes in the image? Reply only with the number.",
                                model: .gemma, in: app, timeout: 600)
        XCTAssertEqual(followup.answer, "7421", "image bytes were not replayed for a follow-up turn")
    }

    @MainActor
    func test19GemmaVisualQuestionDoesNotTriggerAllowedWebSearch() throws {
        let app = try launchApp(visionFixture: true)
        XCTAssertTrue(waitForFixtureCount(1, in: app))
        try configureTools(master: true, enabled: ["Web search"], in: app)
        try openNewChat(in: app)
        try activate(.gemma, in: app)
        let marker = uniqueMarker("VISION_NO_WEB")
        let evidence = try send(
            marker + "\nWhat's in this attached image? Use the pixels only; do not browse the web. Mention the number and both colored shapes.",
            model: .gemma, in: app, timeout: 720)
        XCTAssertFalse(evidence.toolActivities.contains(where: { $0.localizedCaseInsensitiveContains("Web Search") }),
                       "Gemma searched the web for content already present in the attached image")
        XCTAssertTrue(evidence.answer.contains("7421"))
        XCTAssertTrue(evidence.answer.localizedCaseInsensitiveContains("red"))
        XCTAssertTrue(evidence.answer.localizedCaseInsensitiveContains("square"))
        XCTAssertTrue(evidence.answer.localizedCaseInsensitiveContains("blue"))
        XCTAssertTrue(evidence.answer.localizedCaseInsensitiveContains("circle"))
    }

    @MainActor
    func test20SwitchingImageDraftFromGemmaToBonsaiIsBlockedWithoutLosingDraft() throws {
        let app = try launchApp(visionFixture: true)
        XCTAssertTrue(waitForFixtureCount(1, in: app))
        try configureTools(master: false, enabled: [], in: app)
        try openNewChat(in: app)
        try activate(.gemma, in: app)
        let marker = uniqueMarker("VISION_GATE")
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(marker + " describe this image")
        try activate(.bonsai, in: app)
        XCTAssertTrue(waitForFixtureCount(1, in: app), "model switch dropped the staged image")
        XCTAssertEqual(field.value as? String, marker + " describe this image")

        let userCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You said")
        ).count
        XCTAssertTrue(waitForEnabled(app.buttons["Send"], timeout: 10))
        app.buttons["Send"].tap()
        let rejection = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "can't read images")
        ).firstMatch
        XCTAssertTrue(rejection.waitForExistence(timeout: 10),
                      "text-only model did not explain why the image turn was rejected")
        Thread.sleep(forTimeInterval: 5)
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You said")
        ).count, userCount, "unsupported image send created a broken conversation turn")
        XCTAssertEqual(field.value as? String, marker + " describe this image",
                       "unsupported image send lost the user's draft")
        XCTAssertTrue(waitForFixtureCount(1, in: app), "unsupported image send lost the staged image")
    }

    // MARK: Switching / lifecycle / races

    @MainActor
    func test21HistoricalStatsRemainBoundToTheGeneratingModelAfterSwitch() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: false)
        let marker = uniqueMarker("STATS_MODEL")
        let bonsai = try send(
            marker + "\nReply with this complete sentence verbatim and nothing else: "
                + "Bonsai generated this deliberately long historical response so token throughput and "
                + "model ownership remain independently observable after a later local model switch.",
            model: .bonsai, in: app)
        try activate(.gemma, in: app)
        let gemma = try send(
            "Reply with this complete sentence verbatim and nothing else: Gemma generated this deliberately "
                + "long historical response so token throughput and model ownership remain independently "
                + "observable after a later local model switch.",
            model: .gemma, in: app)
        let values = app.descendants(matching: .any).matching(identifier: "assistant.stats")
            .allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
        XCTAssertGreaterThanOrEqual(values.count, 2)
        XCTAssertTrue(bonsai.stats.hasPrefix("Bonsai 8B ·"),
                      "the first committed evidence was attributed to the wrong model: \(bonsai.stats)")
        XCTAssertTrue(gemma.stats.hasPrefix("Gemma 4 E2B ·"),
                      "the second committed evidence was attributed to the wrong model: \(gemma.stats)")
        XCTAssertTrue(values[values.count - 2].hasPrefix("Bonsai 8B ·"),
                      "switching models rewrote old stats: \(values)")
        XCTAssertTrue(values.last?.hasPrefix("Gemma 4 E2B ·") == true)
    }

    @MainActor
    func test22BonsaiBackgroundSuspendAndLazyReload() throws {
        try exerciseBackgroundReload(.bonsai)
    }

    @MainActor
    func test23GemmaBackgroundSuspendAndLazyReload() throws {
        try exerciseBackgroundReload(.gemma)
    }

    @MainActor
    func test24ChangingWebSelectionDuringColdLoadDoesNotAffectCurrentTurn() throws {
        let app = try launchApp()
        try configureTools(master: true, enabled: [], in: app)
        try openNewChat(in: app)
        try activate(.gemma, in: app)
        try goToChatList(in: app)     // suspends the model
        try relaunch(app)             // restores Gemma identity only, resident=false
        try openNewChat(in: app)
        XCTAssertTrue(waitForRuntime("model=gemma-4-e2b", in: app, timeout: 20))
        XCTAssertTrue(waitForRuntime("resident=false", in: app, timeout: 20))

        let copies = app.buttons.matching(identifier: "Copy answer").count
        let stats = app.descendants(matching: .any).matching(identifier: "assistant.stats").count
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(uniqueMarker("TOOL_RACE") + "\nSearch the web for OpenAI's official website and return its title.")
        app.buttons["Send"].tap()
        let started = Date()

        try openChatOptions(in: app)
        let tools = freshMenuElement("Tools", in: app)
        tools.tap()
        let web = freshMenuElement("Web search", in: app)
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        XCTAssertFalse(switchIsOn(web), "Web unexpectedly started enabled before the race")
        web.tap() // must apply to the NEXT send, never the already-submitted turn
        // `web` is invalid after this tap: SwiftUI removes or rebuilds the menu subtree. Do not read its
        // value again. The next turn's exactly-one-Web assertion below is the stronger functional proof
        // that the setting persisted, while this helper safely handles every menu-dismissal outcome.
        try settleChatOptionsAfterToolSelection(in: app)

        let evidence = try waitForCommittedGeneration(model: .gemma, in: app,
                                                       previousCopyCount: copies,
                                                       previousStatsCount: stats,
                                                       startedAt: started)
        XCTAssertFalse(evidence.toolActivities.contains(where: { $0.localizedCaseInsensitiveContains("Web Search") }),
                       "a per-tool change during warming retroactively authorized the current turn")

        // Prove the same selection applies to the following turn. Without this, a failed toggle would
        // make the race assertion pass vacuously.
        let next = try send(
            "Use web search exactly once for the query OpenAI official website, then return its first title.",
            model: .gemma, in: app, timeout: 720)
        XCTAssertEqual(next.toolActivities.count, 1,
                       "the next turn did not receive exactly the newly selected Web tool")
        XCTAssertTrue(next.toolActivities.first?.hasPrefix("Web Search returned ") == true)
    }

    @MainActor
    func test25BuiltInSkillSelectionPersistsPerConversation() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: false)
        app.buttons["Chat options"].tap()
        let skill = app.buttons["Skill"]
        XCTAssertTrue(skill.waitForExistence(timeout: 10))
        skill.tap()
        let concise = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Concise Mode")
        ).firstMatch
        XCTAssertTrue(concise.waitForExistence(timeout: 10))
        concise.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Active skill: Concise Mode")
        ).firstMatch.waitForExistence(timeout: 10))
        let marker = uniqueMarker("SKILL")
        let evidence = try send(marker + "\nExplain why the sky appears blue.", model: .bonsai, in: app)
        XCTAssertFalse(evidence.answer.isEmpty)
        try goToChatList(in: app)
        try relaunch(app)
        try reopenConversation(titled: marker, in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Active skill: Concise Mode")
        ).firstMatch.waitForExistence(timeout: 20), "conversation lost its selected skill after relaunch")
    }

    @MainActor
    func test26AgentRuntimeWiresRunsAndRecoveryInbox() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: false)

        // The production app must be on the durable agent runtime path (rollout-on), not the
        // legacy in-process loop. The diagnostics surface the exact assembly reason on failure.
        let initial = diagnosticValue("device-e2e.agent", in: app)
        XCTAssertTrue(
            initial.contains("enabled=true"),
            "Agent runtime must be wired on device; diagnostics: \(initial)"
        )
        if initial.contains("error="), !initial.contains("error=none") {
            XCTFail("Agent runtime assembly failed on device: \(initial)")
        }

        // A send must produce a durable run projection and a committed assistant answer. Drive the
        // send manually so a generation failure reports the complete agent diagnostics instead of
        // the generic UI message.
        let field = app.textFields["composer.field"]
        guard field.waitForExistence(timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Composer missing before agent send")
        }
        field.tap()
        field.typeText("Reply with exactly: AGENT-ON-DEVICE")
        let sendButton = app.buttons["Send"]
        guard waitForEnabled(sendButton, timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Send did not enable")
        }
        sendButton.tap()
        let deadline = Date().addingTimeInterval(DeviceTestModel.bonsai.generationTimeout)
        var committed = false
        while Date() < deadline {
            if app.staticTexts["Couldn't generate a reply"].exists
                || app.staticTexts["The model didn't reply"].exists
            {
                let diagnostics = diagnosticValue("device-e2e.agent", in: app)
                XCTFail("agent generation failed; diagnostics: \(diagnostics)")
                attachDiagnostics(app, name: "agent-generation-failed")
                return
            }
            if app.buttons.matching(identifier: "Copy answer").count > 0 {
                committed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !committed {
            let diagnostics = diagnosticValue("device-e2e.agent", in: app)
            XCTFail("agent run did not commit; diagnostics: \(diagnostics)")
            attachDiagnostics(app, name: "agent-run-stalled")
            return
        }
        XCTAssertTrue(committed, "agent run did not commit an answer within the deadline")
        let after = diagnosticValue("device-e2e.agent", in: app)
        XCTAssertFalse(after.contains("failure=The"), "run failure surfaced: \(after)")
        XCTAssertTrue(
            after.contains("run=completed"),
            "agent run must project completed; diagnostics: \(after)"
        )

        // A neutral relaunch must not auto-resume, and a completed run must not sit in the
        // recovery inbox (spec §9.4 / §20).
        try relaunch(app)
        let relaunched = diagnosticValue("device-e2e.agent", in: app)
        XCTAssertTrue(
            relaunched.contains("recoverable=0"),
            "completed runs must not surface as recoverable; diagnostics: \(relaunched)"
        )
    }

    @MainActor
    func test27AgentRuntimeDiagnosticProbe() throws {
        let app = try prepare(.bonsai, tools: false, selected: [], thinking: true)
        let field = app.textFields["composer.field"]
        guard field.waitForExistence(timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Composer missing before agent probe")
        }
        field.tap()
        field.typeText(
            "E2E_BONSAI_THINK_PROBE\n"
                + "Solve this carefully: find the smallest positive integer divisible by every integer "
                + "from 1 through 18, and explain the prime-factor reasoning before the final number."
        )
        let sendButton = app.buttons["Send"]
        guard waitForEnabled(sendButton, timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Send did not enable")
        }
        sendButton.tap()
        // Short probe: the worker either commits or fails quickly; read the diagnostics either way.
        let deadline = Date().addingTimeInterval(300)
        var committed = false
        var failed = false
        while Date() < deadline {
            if app.buttons.matching(identifier: "Copy answer").count > 0 {
                committed = true
                break
            }
            let diagnostics = diagnosticValue("device-e2e.agent", in: app)
            if diagnostics.contains("run=failed") || diagnostics.contains("run=cancelled") {
                failed = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if failed || !committed {
            // Let the diagnostics overlay's 1s poll pick up the worker log before reading.
            Thread.sleep(forTimeInterval: 3)
        }
        let diagnostics = diagnosticValue("device-e2e.agent", in: app)
        if committed {
            XCTAssertTrue(diagnostics.contains("run=completed"), "probe diagnostics: \(diagnostics)")
        } else if failed {
            XCTFail("agent probe failed; diagnostics: \(diagnostics)")
        } else {
            XCTFail("agent probe stalled; diagnostics: \(diagnostics)")
        }
    }

    // This method is deliberately last in the serial suite. It uses only the public, chat-only and
    // Memory-only deletion surfaces; "Erase all app data" is never touched because that also deletes the
    // expensive model artifacts the matrix was asked to preserve.
    @MainActor
    func test99CleanupChatsMemoryAndTestMutatedSettingsWithoutDeletingModels() throws {
        let app = try launchApp()
        let inventoryBefore = diagnosticValue("device-e2e.inventory", in: app)
        var failures: [String] = []

        if !inventoryBefore.contains(DeviceTestModel.bonsai.variantID) {
            failures.append("Pre-cleanup inventory is missing \(DeviceTestModel.bonsai.variantID)")
        }
        if !inventoryBefore.contains(DeviceTestModel.gemma.variantID) {
            failures.append("Pre-cleanup inventory is missing \(DeviceTestModel.gemma.variantID)")
        }

        do {
            try forgetAllMemories(in: app)
        } catch {
            failures.append("Memory cleanup failed: \(error.localizedDescription)")
            try? relaunch(app)
        }

        do {
            try restoreSettingsMutatedByDeviceMatrix(in: app)
        } catch {
            failures.append("Settings cleanup failed: \(error.localizedDescription)")
            try? relaunch(app)
        }

        // A fresh install's fallback identity is Bonsai. Restore that identity only when necessary, then
        // delete the temporary conversation below and relaunch so the weights are not left resident.
        if !diagnosticValue("device-e2e.runtime", in: app).contains("model=bonsai-8b") {
            do {
                try openNewChat(in: app)
                try activate(.bonsai, in: app)
            } catch {
                failures.append("Default-model identity cleanup failed: \(error.localizedDescription)")
                try? relaunch(app)
            }
        }

        do {
            try deleteAllChatsThroughSettings(in: app)
        } catch {
            failures.append("Chat cleanup failed: \(error.localizedDescription)")
            try? relaunch(app)
        }

        // Re-open Memory after a process boundary: the empty state must come from disk, not from the sheet's
        // in-memory mirror. Close it again before the final cold-launch assertions.
        do {
            try relaunch(app)
            try verifyMemoryIsEmpty(in: app)
        } catch {
            failures.append("Post-relaunch Memory verification failed: \(error.localizedDescription)")
            try? relaunch(app)
        }

        do {
            try goToChatList(in: app)
            try relaunch(app)
        } catch {
            failures.append("Final cold relaunch failed: \(error.localizedDescription)")
        }

        let inventoryAfter = diagnosticValue("device-e2e.inventory", in: app)
        let runtimeAfter = diagnosticValue("device-e2e.runtime", in: app)
        if inventoryAfter != inventoryBefore {
            failures.append("Model inventory changed during cleanup. Before=\(inventoryBefore); after=\(inventoryAfter)")
        }
        if !app.staticTexts["No conversations yet"].waitForExistence(timeout: 20) {
            failures.append("Chat list is not empty after cleanup")
        }
        if !runtimeAfter.contains("model=bonsai-8b") {
            failures.append("Fresh fallback identity is not Bonsai: \(runtimeAfter)")
        }
        if !runtimeAfter.contains("resident=false") || !runtimeAfter.contains("phase=idle") {
            failures.append("Final launch is not cold and idle: \(runtimeAfter)")
        }

        let report = XCTAttachment(string: """
        inventory_before=\(inventoryBefore)
        inventory_after=\(inventoryAfter)
        runtime_after=\(runtimeAfter)
        failures=\(failures.isEmpty ? "none" : failures.joined(separator: "\n- "))
        """)
        report.name = "physical-device-cleanup"
        report.lifetime = .keepAlways
        add(report)
        attachDiagnostics(app, name: "physical-device-cleanup-final")

        XCTAssertTrue(failures.isEmpty,
                      "Cleanup had \(failures.count) independent failure(s):\n- "
                          + failures.joined(separator: "\n- "))
    }

    // MARK: Helpers

    @MainActor
    private func prepare(_ model: DeviceTestModel,
                         tools: Bool,
                         selected: Set<String>,
                         thinking: Bool) throws -> XCUIApplication {
        let app = try launchApp()
        try setThinkingDefault(thinking, in: app)
        try configureTools(master: tools, enabled: selected, in: app)
        // ChatStore snapshots the per-conversation Thinking default at construction. Relaunch after
        // changing Settings so every case starts with the requested mode instead of inherited test state.
        try relaunch(app)
        try openNewChat(in: app)
        try activate(model, in: app)
        return app
    }

    @MainActor
    private func forgetAllMemories(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let memory = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Memory")
        ).firstMatch
        guard scrollToHittable(memory, in: app.scrollViews.firstMatch, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Memory settings row is unreachable during cleanup")
        }
        memory.tap()
        guard app.navigationBars["Memory"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory sheet did not open during cleanup")
        }

        let empty = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Nothing saved yet.")
        ).firstMatch
        let forget = app.buttons["Forget everything"].firstMatch
        if !empty.waitForExistence(timeout: 2) {
            guard scrollToHittable(forget, in: firstHittableScrollView(in: app)) else {
                throw DeviceE2EHarnessError.precondition(
                    "Memory is neither empty nor exposing Forget everything"
                )
            }
            forget.tap()
            let alert = app.alerts["Forget everything?"]
            guard alert.waitForExistence(timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("Forget-everything confirmation did not appear")
            }
            alert.buttons["Forget everything"].tap()
        }

        guard empty.waitForExistence(timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Memory did not reach its empty state")
        }
        let done = app.navigationBars["Memory"].buttons["Done"]
        guard done.exists, done.isHittable else {
            throw DeviceE2EHarnessError.precondition("Memory cleanup has no actionable Done button")
        }
        done.tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory sheet did not close after cleanup")
        }
    }

    @MainActor
    private func verifyMemoryIsEmpty(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let memory = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Memory")
        ).firstMatch
        guard scrollToHittable(memory, in: app.scrollViews.firstMatch, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Memory settings row is unreachable during verification")
        }
        memory.tap()
        guard app.navigationBars["Memory"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory sheet did not open during verification")
        }
        let empty = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Nothing saved yet.")
        ).firstMatch
        guard empty.waitForExistence(timeout: 20), !app.buttons["Forget everything"].exists else {
            throw DeviceE2EHarnessError.precondition("Memory was not durably empty after relaunch")
        }
        app.navigationBars["Memory"].buttons["Done"].tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory verification sheet did not close")
        }
    }

    /// The matrix starts from a clean install and mutates only these persisted preferences. Restore their
    /// exact fresh-install values without using the full-app erase path: Thinking on, Tools authorization
    /// off, the six non-private built-ins and both search engines selected, private tools deselected, and
    /// the stock system prompt restored.
    @MainActor
    private func restoreSettingsMutatedByDeviceMatrix(in app: XCUIApplication) throws {
        try setThinkingDefault(true, in: app)
        try configureTools(
            master: false,
            enabled: ["Web search", "Webpage reader", "Wikipedia", "Calculator", "Clock", "Memory"],
            in: app)

        try goToSettings(in: app)
        let choose = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Choose tools")
        ).firstMatch
        guard scrollToHittable(choose, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Choose tools is unreachable while restoring defaults")
        }
        choose.tap()
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not open while restoring defaults")
        }
        let toolsScroll = firstHittableScrollView(in: app)
        for title in ["Calendar", "Reminders", "Location"] {
            let toggle = switchStarting(with: title, in: app)
            guard scrollToHittable(toggle, in: toolsScroll) else {
                throw DeviceE2EHarnessError.precondition("Private tool toggle is unreachable: \(title)")
            }
            try setSwitch(toggle, on: false)
        }
        for title in ["DuckDuckGo", "Bing"] {
            let toggle = switchStarting(with: title, in: app)
            guard scrollToHittable(toggle, in: toolsScroll, swipingUp: false) else {
                throw DeviceE2EHarnessError.precondition("Search-engine toggle is unreachable: \(title)")
            }
            try setSwitch(toggle, on: true)
        }
        let master = switchStarting(with: "Allow selected tools", in: app)
        guard scrollToHittable(master, in: toolsScroll, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Tool master switch is unreachable during cleanup")
        }
        try setSwitch(master, on: false)
        app.navigationBars["Tools"].buttons["Done"].tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not close after restoring defaults")
        }

        let systemPrompt = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "System prompt")
        ).firstMatch
        guard scrollToHittable(systemPrompt, in: app.scrollViews.firstMatch, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("System prompt row is unreachable during cleanup")
        }
        systemPrompt.tap()
        guard app.navigationBars["System prompt"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("System prompt editor did not open")
        }
        let reset = app.buttons["Reset to the standard prompt"]
        if reset.exists, reset.isHittable { reset.tap() }
        app.navigationBars["System prompt"].buttons["Done"].tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("System prompt editor did not close")
        }
    }

    @MainActor
    private func deleteAllChatsThroughSettings(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let delete = app.buttons["Delete all chats"].firstMatch
        guard scrollToHittable(delete, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Delete all chats is unreachable")
        }
        delete.tap()
        let alert = app.alerts["Delete all chats?"]
        guard alert.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Delete-all-chats confirmation did not appear")
        }
        alert.buttons["Delete all chats"].tap()
        try goToChatList(in: app)
        guard app.staticTexts["No conversations yet"].waitForExistence(timeout: 30) else {
            throw DeviceE2EHarnessError.precondition("Conversations remain after Delete all chats")
        }
    }

    @MainActor
    private func exerciseStopAndRecovery(_ model: DeviceTestModel,
                                         in app: XCUIApplication) throws {
        let marker = uniqueMarker(model == .bonsai ? "BONSAI_STOP" : "GEMMA_STOP")
        let copies = app.buttons.matching(identifier: "Copy answer").count
        let statsBefore = app.descendants(matching: .any).matching(identifier: "assistant.stats").count
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(marker + "\nWrite a detailed 2500-word technical essay comparing ten sorting algorithms, with proofs and examples. Do not finish early.")
        app.buttons["Send"].tap()
        let stop = app.buttons["Stop"]
        XCTAssertTrue(waitForEnabled(stop, timeout: model.loadTimeout), "Stop never became actionable")
        XCTAssertTrue(waitForRuntime(model == .bonsai ? "phase=thinking" : "phase=answering",
                                     in: app, timeout: 120),
                      "Stop test never reached active token generation")
        Thread.sleep(forTimeInterval: 2)
        stop.tap()
        XCTAssertTrue(waitUntilGone(stop, timeout: 20), "Stop did not settle at a token boundary")

        let stopped = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Stopped")
        ).firstMatch
        let stats = app.descendants(matching: .any).matching(identifier: "assistant.stats")
            .allElementsBoundByIndex.last
        let statsValue = stats.flatMap { ($0.value as? String) ?? $0.label } ?? ""
        XCTAssertTrue(stopped.exists || statsValue.contains("stop: cancelled"),
                      "stopped turn is neither marked Stopped nor cancelled: \(statsValue)")
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 10))

        // A reasoning-only stop exposes Retry. Prove that action starts a fresh generation, then stop the
        // intentionally long retry so the recovery turn below remains bounded.
        let retry = app.buttons["Retry"]
        if retry.exists {
            retry.tap()
            XCTAssertTrue(waitForEnabled(app.buttons["Stop"], timeout: model.loadTimeout),
                          "Retry did not start a fresh generation")
            app.buttons["Stop"].tap()
            XCTAssertTrue(waitUntilGone(app.buttons["Stop"], timeout: 20))
        }

        let recovery = try send("Reply exactly RECOVERED and nothing else.", model: model, in: app)
        XCTAssertEqual(recovery.answer, "RECOVERED", "model could not generate after Stop")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "Copy answer").count, copies + 1)
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any)
            .matching(identifier: "assistant.stats").count, statsBefore + 1)
    }

    @MainActor
    private func exerciseCalculator(_ model: DeviceTestModel) throws {
        let app = try prepare(model, tools: true, selected: ["Calculator"], thinking: false)
        let marker = uniqueMarker(model == .bonsai ? "BONSAI_CALC" : "GEMMA_CALC")
        let evidence = try send(
            marker + "\nUse the calculator exactly once to multiply 1234567 by 7654321. Then reply exactly RESULT=9449772114007.",
            model: model, in: app)
        XCTAssertEqual(evidence.toolActivities.count, 1, "unexpected tool chain: \(evidence.toolActivities)")
        XCTAssertEqual(evidence.toolActivities.first, "Calculator returned 9449772114007")
        // The functional contract is that the tool's exact output reached the user, not that a
        // 1-bit local model echoes a prescribed literal; it may phrase the same number in its own words.
        XCTAssertTrue(evidence.answer.contains("9449772114007"),
                      "answer must carry the computed result: \(evidence.answer)")
    }

    @MainActor
    private func exerciseClock(_ model: DeviceTestModel) throws {
        let app = try prepare(model, tools: true, selected: ["Clock"], thinking: false)
        let marker = uniqueMarker(model == .bonsai ? "BONSAI_CLOCK" : "GEMMA_CLOCK")
        var evidence = try send(
            marker + "\nUse the clock exactly once to get the current local date and time, then answer in one short line.",
            model: model, in: app)
        if evidence.toolActivities.isEmpty {
            // A 1-bit local model occasionally answers from its training prior instead of calling
            // the clock. A wiring regression fails earlier with run=failed diagnostics, so a single
            // retry keeps the functional tool contract from depending on sampling luck.
            let retryMarker = uniqueMarker(model == .bonsai ? "BONSAI_CLOCK_RETRY" : "GEMMA_CLOCK_RETRY")
            evidence = try send(
                retryMarker + "\nYou must call the clock tool before answering. Use the clock exactly once "
                    + "to get the current local date and time, then answer in one short line.",
                model: model, in: app)
        }
        XCTAssertEqual(evidence.toolActivities.count, 1, "unexpected tool chain: \(evidence.toolActivities)")
        XCTAssertTrue(evidence.toolActivities.first?.hasPrefix("Current Datetime returned ") == true)
    }

    @MainActor
    private func exerciseWebSearch(_ model: DeviceTestModel) throws {
        let app = try prepare(model, tools: true, selected: ["Web search"], thinking: false)
        let marker = uniqueMarker(model == .bonsai ? "BONSAI_WEB" : "GEMMA_WEB")
        let evidence = try send(
            marker + "\nUse web search exactly once for the query OpenAI official website. Then answer with the first result's title.",
            model: model, in: app, timeout: 720)
        XCTAssertEqual(evidence.toolActivities.count, 1, "unexpected tool chain: \(evidence.toolActivities)")
        guard let activity = evidence.toolActivities.first else { return }
        XCTAssertTrue(activity.hasPrefix("Web Search returned "))
        XCTAssertFalse(activity.localizedCaseInsensitiveContains("No web results"),
                       "Web Search was presented as success despite returning no results")
        XCTAssertFalse(activity.localizedCaseInsensitiveContains("failed"))
    }

    @MainActor
    private func addManualMemory(_ sentence: String, in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let memory = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Memory")
        ).firstMatch
        guard scrollToHittable(memory, in: app.scrollViews.firstMatch, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Memory settings row is unreachable")
        }
        memory.tap()
        XCTAssertTrue(app.navigationBars["Memory"].waitForExistence(timeout: 15))
        app.buttons["Add a memory"].tap()
        XCTAssertTrue(app.navigationBars["New memory"].waitForExistence(timeout: 10))
        let editor = app.textViews["Memory text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(sentence)
        app.navigationBars["New memory"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Memory"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[sentence].waitForExistence(timeout: 15))
    }

    @MainActor
    private func openMemoryAndFind(_ fragment: String,
                                   in app: XCUIApplication) throws -> XCUIElement {
        try goToSettings(in: app)
        let memory = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Memory")
        ).firstMatch
        XCTAssertTrue(scrollToHittable(memory, in: app.scrollViews.firstMatch, swipingUp: false))
        memory.tap()
        XCTAssertTrue(app.navigationBars["Memory"].waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        guard row.waitForExistence(timeout: 15) else {
            attachDiagnostics(app, name: "memory-missing-\(fragment)")
            throw DeviceE2EHarnessError.precondition("Memory fact is missing: \(fragment)")
        }
        return row
    }

    @MainActor
    private func exerciseCrossModelMemory(writer: DeviceTestModel,
                                          reader: DeviceTestModel) throws {
        // Web is deliberately also authorized: this reproduces the reported sequence where a model saved
        // memory and then unexpectedly started browsing. The turn must use Memory and zero Web calls.
        let app = try prepare(writer, tools: true,
                              selected: ["Memory", "Web search"], thinking: false)
        // One fact on the device only: a stale fact from an earlier run makes the reader's exact-name
        // answer depend on which of two similar notes a 1-bit model happens to pick.
        try clearAllMemories(in: app)
        try openNewChat(in: app)
        try activate(writer, in: app)
        let code = (writer == .bonsai ? "QuartzBonsai" : "QuartzGemma")
            + String(Int.random(in: 10_000...99_999))
        let marker = uniqueMarker(writer == .bonsai ? "BONSAI_MEMORY" : "GEMMA_MEMORY")
        var failures: [String] = []
        var writerEvidence: GenerationEvidence?
        var readerEvidence: GenerationEvidence?
        var persistedText: String?
        var persistedProvenance: String?

        // Defer all content assertions: a wrong acknowledgement must not prevent us from observing whether
        // the Memory tool ran, whether it wrote durable state, or whether another model consumed that state.
        do {
            let evidence = try send(
                marker + "\nMy temporary device-test name is \(code). Please remember this lasting fact "
                    + "using the memory tool. Do not use web search. After it is saved, reply exactly "
                    + "MEMORY_SAVED_OK.",
                model: writer, in: app, assertEvidence: false)
            writerEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: writer)
                .map { "Writer generation: \($0)" }
            if evidence.answer != "MEMORY_SAVED_OK" {
                failures.append("Writer answer was \(String(reflecting: evidence.answer)), expected MEMORY_SAVED_OK")
            }
            if !evidence.toolActivities.contains("Saved to memory") {
                failures.append("Writer did not expose a successful Memory tool row: \(evidence.toolActivities)")
            }
            if evidence.toolActivities.contains(where: { $0.localizedCaseInsensitiveContains("Web Search") }) {
                failures.append("Writer unexpectedly invoked Web Search: \(evidence.toolActivities)")
            }
        } catch {
            failures.append("Writer turn did not commit inspectable evidence: \(error.localizedDescription)")
        }

        // Relaunch before reading the sheet so this proves the fact was persisted, not merely left in the
        // current MemoryBook mirror. Missing state is recorded but does not stop the cross-model probe.
        do {
            try relaunch(app)
            try goToSettings(in: app)
            let memory = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Memory")
            ).firstMatch
            guard scrollToHittable(memory, in: app.scrollViews.firstMatch, swipingUp: false) else {
                throw DeviceE2EHarnessError.precondition("Memory settings row is unreachable")
            }
            memory.tap()
            guard app.navigationBars["Memory"].waitForExistence(timeout: 15) else {
                throw DeviceE2EHarnessError.precondition("Memory sheet did not open")
            }
            let row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", code)
            ).firstMatch
            if row.waitForExistence(timeout: 20) {
                persistedText = row.label
                persistedProvenance = row.value as? String
                if !row.label.hasPrefix("The user") {
                    failures.append("Persisted memory is not canonical English: \(row.label)")
                }
                if row.label.contains("用户") {
                    failures.append("Chinese text leaked into canonical memory: \(row.label)")
                }
                if !(persistedProvenance?.hasPrefix("Saved by mobileLLM ·") == true) {
                    failures.append("Persisted fact has wrong provenance: \(persistedProvenance ?? "<missing>")")
                }
            } else {
                attachDiagnostics(app, name: "memory-missing-\(code)")
                failures.append("No durable Memory row contains \(code) after relaunch")
            }
        } catch {
            failures.append("Durable Memory inspection failed: \(error.localizedDescription)")
        }

        if app.navigationBars["Memory"].exists {
            let done = app.navigationBars["Memory"].buttons["Done"]
            if done.exists, done.isHittable {
                done.tap()
                if !app.navigationBars["Settings"].waitForExistence(timeout: 15) {
                    failures.append("Memory sheet did not close after durable-state inspection")
                }
            }
        }

        do {
            try configureTools(master: false, enabled: ["Memory"], in: app)
            try openNewChat(in: app)
            try activate(reader, in: app)
            let evidence = try send(
                "What is my temporary device-test name? Reply only with the exact name.",
                model: reader, in: app, assertEvidence: false)
            readerEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: reader)
                .map { "Reader generation: \($0)" }
            if evidence.answer != code {
                failures.append("Reader answered \(String(reflecting: evidence.answer)), expected \(code)")
            }
            if !evidence.toolActivities.isEmpty {
                failures.append("Reader invoked tools while the master switch was off: \(evidence.toolActivities)")
            }
        } catch {
            failures.append("Cross-model recall probe did not complete: \(error.localizedDescription)")
        }

        let summary = XCTAttachment(string: """
        writer=\(writer.displayName)
        reader=\(reader.displayName)
        expected_code=\(code)
        writer_answer=\(writerEvidence?.answer ?? "<no evidence>")
        writer_tools=\(writerEvidence?.toolActivities.joined(separator: " | ") ?? "<no evidence>")
        persisted_text=\(persistedText ?? "<missing>")
        persisted_provenance=\(persistedProvenance ?? "<missing>")
        reader_answer=\(readerEvidence?.answer ?? "<no evidence>")
        reader_tools=\(readerEvidence?.toolActivities.joined(separator: " | ") ?? "<no evidence>")
        failures=\(failures.isEmpty ? "none" : failures.joined(separator: "\n- "))
        """)
        summary.name = "cross-model-memory-\(writer.modelID)-to-\(reader.modelID)"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertTrue(failures.isEmpty,
                      "Cross-model Memory path had \(failures.count) independent failure(s):\n- "
                          + failures.joined(separator: "\n- "))
    }

    @MainActor
    private func exerciseBackgroundReload(_ model: DeviceTestModel) throws {
        let app = try prepare(model, tools: false, selected: [], thinking: false)
        let expectedBefore = "7319"
        let expectedAfter = "8426"
        var failures: [String] = []
        var beforeEvidence: GenerationEvidence?
        var afterEvidence: GenerationEvidence?
        var afterCopyCount: Int?
        var afterStatsCount: Int?

        // Evidence validation is deliberately deferred: a stats-presentation defect must not prevent the
        // test from exercising background suspension and the subsequent lazy reload.
        do {
            let evidence = try send(
                "Reply with only the number \(expectedBefore).",
                model: model, in: app, assertEvidence: false)
            beforeEvidence = evidence
            failures += generationEvidenceFailures(evidence, model: model)
                .map { "Before-background generation: \($0)" }
            if evidence.answer != expectedBefore {
                failures.append(
                    "Before-background answer was \(String(reflecting: evidence.answer)); "
                        + "expected exactly \(expectedBefore)"
                )
            }
        } catch {
            failures.append("Before-background generation failed: \(error.localizedDescription)")
        }

        // Stage the second turn while the app is still foregrounded. On current iOS betas, XCUITest
        // `typeText` immediately after reactivation can surface a cross-device paste permission alert;
        // the safety firewall must not click that alert. Keeping the draft across background and tapping
        // Send after foreground still exercises the real suspend -> lazy-load -> generation boundary.
        let field = app.textFields["composer.field"]
        if field.waitForExistence(timeout: 20), field.isHittable {
            afterCopyCount = app.buttons.matching(identifier: "Copy answer").count
            afterStatsCount = app.descendants(matching: .any)
                .matching(identifier: "assistant.stats").count
            field.tap()
            field.typeText("Reply with only the number \(expectedAfter).")
            if !waitForEnabled(app.buttons["Send"], timeout: 20) {
                failures.append("The staged after-background draft did not enable Send")
                afterCopyCount = nil
                afterStatsCount = nil
            }
        } else {
            failures.append("Composer was unavailable while staging the after-background turn")
        }

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        let conversationRestored = app.buttons["Active model"].waitForExistence(timeout: 30)
        if !conversationRestored {
            failures.append("Conversation UI did not return after foreground activation")
        }

        let suspended = waitForRuntime("resident=false", in: app, timeout: 60)
        if !suspended {
            failures.append(
                "Backgrounding did not suspend resident weights: "
                    + diagnosticValue("device-e2e.runtime", in: app)
            )
        }

        if conversationRestored, let copyCount = afterCopyCount, let statsCount = afterStatsCount {
            do {
                let startedAt = Date()
                let sendButton = app.buttons["Send"]
                guard waitForEnabled(sendButton, timeout: 20) else {
                    throw DeviceE2EHarnessError.precondition(
                        "The staged after-background draft was not sendable after foreground activation"
                    )
                }
                sendButton.tap()
                let evidence = try waitForCommittedGeneration(
                    model: model,
                    in: app,
                    previousCopyCount: copyCount,
                    previousStatsCount: statsCount,
                    startedAt: startedAt
                )
                afterEvidence = evidence
                failures += generationEvidenceFailures(evidence, model: model)
                    .map { "After-background generation: \($0)" }
                if evidence.answer != expectedAfter {
                    failures.append(
                        "After-background answer was \(String(reflecting: evidence.answer)); "
                            + "expected exactly \(expectedAfter)"
                    )
                }
            } catch {
                failures.append("After-background generation failed: \(error.localizedDescription)")
            }
        } else if !conversationRestored {
            failures.append("After-background generation was unavailable because the conversation UI was absent")
        } else {
            failures.append("After-background generation was unavailable because its draft was not staged")
        }

        let reloaded = waitForRuntime("resident=true", in: app, timeout: 30)
        if !reloaded {
            failures.append(
                "The next send did not lazily reload resident weights: "
                    + diagnosticValue("device-e2e.runtime", in: app)
            )
        }

        let summary = XCTAttachment(string: """
        model=\(model.displayName)
        expected_before=\(expectedBefore)
        actual_before=\(beforeEvidence?.answer ?? "<no evidence>")
        before_stats=\(beforeEvidence?.stats ?? "<no evidence>")
        suspended=\(suspended)
        expected_after=\(expectedAfter)
        actual_after=\(afterEvidence?.answer ?? "<no evidence>")
        after_stats=\(afterEvidence?.stats ?? "<no evidence>")
        reloaded=\(reloaded)
        runtime_final=\(diagnosticValue("device-e2e.runtime", in: app))
        failures=\(failures.isEmpty ? "none" : failures.joined(separator: "\n- "))
        """)
        summary.name = "background-reload-\(model.modelID)"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertTrue(failures.isEmpty,
                      "\(model.displayName) background lifecycle had \(failures.count) independent "
                          + "failure(s):\n- " + failures.joined(separator: "\n- "))
    }
}

private extension XCUIElementQuery {
    var lastMatch: XCUIElement { element(boundBy: max(0, count - 1)) }
}

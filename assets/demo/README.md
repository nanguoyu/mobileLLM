# README captures

Refreshed through 2026-10-25 from the redesigned mobileLLM UI on the iPhone 17 Simulator with iOS 27.
The app used separate real stores for these demos. The online captures below used no fixed-response
transport. The separately labeled acceptance regression capture at the end uses controlled responses.

| File | What it shows |
| --- | --- |
| `chat.png` | A real `deepseek-v4-flash` response with two completed Calculator calls. |
| `models.png` | The compact Featured catalog filtered to Qwen. Memory badges reflect the Simulator's reported hardware. |
| `tools.png` | Individual tool permissions in Settings. |
| `workflow.png` | Three worker tasks grouped into parallel analysis and a dependent release checklist. Coordinator calls are separate. |
| `task-inputs.png` | The release checklist's public output and links to the exact earlier storage and sync results. |
| `workflow-dark.png` | The same workspace in system Dark Mode. |
| `agent-conversation.png` | A real agent follow-up adopts a changed requirement, then recalls it after an app restart. |
| `models.gif` | Finishing a search, inspecting options and comparing models. A 20.1-second recording at 2× speed. |
| `workflow.gif` | Inspecting a saved task and following an input link. A continuous 22.4-second excerpt at 2× speed. |

The chat and workflow used the configured DeepSeek `deepseek-v4-flash` service. Responses were not edited.
The recipe task ran at `99ff571`; the latest UI reads those same saved outputs without rerunning the model.
The complete workflow prompt is reproduced in the root README. The bill prompt was:

> Split a EUR 186 dinner bill among six people, including a 10% tip. Use the calculator and show the total and each person's share.

The agent-conversation capture uses UI revision `c4b4597`. Three real follow-ups ran at `f2ef16d`
in the recipe task's storage agent, retaining the original result. The app restarted between the
second and third follow-up. The final question did not repeat the project, database or retention
values. [Saved inputs and responses](../../docs/evaluations/evidence/2026-10-24-agent-sessions.json)
record this interactive continuation case.

Still images are original 1206 × 2622 Simulator screenshots. GIFs are converted from Simulator
recordings to 440-pixel width and 10 fps with a 128-color palette. Both clips change playback speed
as specified above. These are interface demonstrations; task-quality evaluations remain in
[the current status document](../../docs/STATUS.md).

To refresh, capture the real app with a separate demo conversation, check every frame for private
content, and replace these files. Keep the provider, capture date, and playback speed accurate.

`acceptance-review-fixture.png` was captured on October 26 from the passing Simulator UI regression
at `bbf6401`. It uses controlled model responses in isolated stores and shows criterion-level assessment,
the original-report disclosure and links to three actual fixture producer results. It is an original
1206 × 2622 screenshot, exported from `AcceptanceUIFixed.xcresult`, not real-model task-quality evidence.
The corresponding real model runs and all failures are recorded in
[the acceptance evaluation](../../docs/evaluations/2026-10-26-acceptance-loops.md).

The October 25 `goal-update.gif` is a continuous excerpt from seconds 15–53 of the original 326.8-second
Simulator recording, played at 2× speed. It shows a live goal update, not a simulated response. The task
completed in 113.919 seconds; later idle time in the recording is excluded. `goal-result.jpg` is the
368 × 800 optimized screenshot returned by XcodeBuildMCP after opening the actual final result.
The earlier PNG captures retain their original resolution. The runtime was `998b944`, with response
fixtures disabled. The failed earlier attempt and the successful fresh launch are both documented in
[the public evidence](../../docs/evaluations/evidence/2026-10-25-live-goal-update.json).

October 26 captures use the real museum-catalogue task. `goal-paused.png` shows a paused goal before
app termination; cold relaunch preserved call identities and usage until Resume. That earlier run's
content exceeded its word limit and is recorded as a format failure, not a successful outcome.
`validated-plan.png` shows a later real run after native output checks: its complete final answer has
123 words. The rejected-result capture and task graph show the same later run's preserved originals
and current dependencies. These new PNG files are original 1206 × 2622 Simulator captures.

`goal-tasks.png` and `goal-rejected.png` were inspected after the final UI changes at `5c65c69`.
Visible groups are numbered in dependency order, with historical inputs available through links.
The rejected original is labeled “Result not accepted”, including in source/history navigation.
These views read the already-completed `9bc79be` task and do not regenerate its results.

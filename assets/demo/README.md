# README captures

Refreshed on 2026-10-24 from the redesigned mobileLLM UI on the iPhone 17 Simulator with iOS 27.
The app used separate real stores for this demo. No fixed-response transport was enabled.

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

# README captures

Captured on 2026-10-24 from mobileLLM running on the iPhone 17 Simulator with iOS 27.
The app used separate real stores for this demo. No fixed-response transport was enabled.

| File | What it shows |
| --- | --- |
| `chat.png` | A real `deepseek-v4-flash` response with two completed Calculator calls. |
| `models.png` | The Featured catalog filtered to Qwen. Memory badges reflect the Simulator's reported hardware. |
| `tools.png` | Individual tool permissions in Settings. |
| `workflow.png` | Three completed workers: storage, sync, and a plan using their results. The list also includes two coordinator calls. |
| `models.gif` | A 12.3-second excerpt of model search and scrolling, at original speed. |
| `workflow.gif` | A continuous 46-second excerpt from submission to completed agent calls, played at 3× speed. |

The chat and workflow used the configured DeepSeek service. Its saved display name in this
development profile is “OpenAI”, which appears in the chat header. Responses were not edited.
The reading-list prompt is reproduced in the root README. The bill prompt was:

> Split a EUR 186 dinner bill among six people, including a 10% tip. Use the calculator and show the total and each person's share.

Still images are original 1206 × 2622 Simulator screenshots. GIFs are converted from Simulator
recordings to 440-pixel width and 10 fps with a 128-color palette. Only the workflow clip changes
playback speed. These are interface demonstrations; task-quality evaluations remain in
[the current status document](../../docs/STATUS.md).

To refresh, capture the real app with a separate demo conversation, check every frame for private
content, and replace these files. Keep the provider, capture date, and playback speed accurate.

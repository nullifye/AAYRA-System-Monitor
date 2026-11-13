# Agent percentages

The first five enabled agents in the sorted **Show Agents** list have individual cards. The sixth and later agents share **Other Agents**, preserving that same order regardless of whether they report account allowance or context usage. Dragging or enabling/disabling agents updates this grouping automatically.

The eye controls in **Agent Usage → Show Agents** allow up to three agents in the menu bar. Every supported agent has an explicit percentage meaning:

| Reading | White | Orange | Red |
|---|---|---|---|
| Account allowance remaining | >30% | >10%–30% | ≤10% |
| Context used | <70% | 70%–<90% | ≥90% |

The tooltip identifies the meaning. Context readings derived from a response are labelled as estimates and include the observation time. They are separate from today's cumulative token counts.

## Sources

| Agent | Percentage source |
|---|---|
| Gemini CLI | Existing Google OAuth access token; Code Assist `loadCodeAssist` and `retrieveUserQuota` endpoints, using `remainingFraction` and `resetTime` per quota bucket. |
| Qwen Code | Latest saved assistant `usageMetadata.promptTokenCount` and `contextWindowSize` in project JSONL recordings. |
| Cline | Latest task `api_req_started` metadata, including input, output and cache counts; model identity from `modelInfo`. Also reads CLI reply metrics. |
| Roo Code | Latest task request metadata; cached input is already included in current `tokensIn` values. |
| Kilo Code | Extension task metadata or the latest assistant usage metadata in the local SQLite session database. |
| Kimi | Native `StatusUpdate.context_usage` (0–1), `context_tokens`, and `max_context_tokens` in wire recordings. Partial updates preserve unchanged fields. |
| Pi / Oh My Pi | Latest valid assistant usage on the saved active session branch, including cache tokens. Compaction clears pre-compaction readings until a new response is recorded. |
| Cherry Studio | Saved agent transcripts and structured context snapshots when present in those recordings. |
| ZCode | Read-only assistant message metadata, or latest non-compaction model usage in its SQLite session database. |
| Perch AI | Existing thread context snapshots. |

Explicit recorded capacities take precedence, followed by configured custom-model capacities. For known models without a recorded capacity, AAYRA bundles a compact capacity-only snapshot of the [Oh My Pi model catalog](https://github.com/can1357/oh-my-pi/blob/main/packages/catalog/src/models.json), retrieved 2026-11-13. Provider and model identities are matched exactly; an unqualified model is used only when all catalog providers agree on its capacity. These fallback readings are estimates: provider overrides or changes after the catalog snapshot can make the real capacity different.

The integrations are read-only. They do not modify agent configuration, start a model conversation, install extensions, or attach to an existing live RPC session. Some agent versions expose context only in a live API and omit the required metadata from disk; AAYRA shows **Unavailable / —** in those cases rather than inferring capacity from cumulative spend. Unknown models, scan limits, missing files, and sessions older than 24 hours also yield unavailable readings. Not every installed version has been tested live.

Gemini quota support requires an unexpired Google sign-in belonging to Gemini CLI. API-key-only installations do not provide this account quota. AAYRA never redeems refresh tokens or writes credentials. Requests use provider pacing, redirect rejection, and 429 backoff. A full quota can omit `remainingAmount`; `remainingFraction: 1` still correctly means 100% remaining. These are the quota buckets Google reports, which may not describe every backend limit.

Only shown agents are read while the panel is open. With the panel closed, only pinned agents refresh; context readers may read bounded session metadata, but the daily-token scanner is not run. Session content, credentials and model configuration are never uploaded by these readers. The model catalog is bundled; it is not fetched in the background.

Upstream references: [Gemini quota schema](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts), [Qwen recording format](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/services/chatRecordingService.ts), [Kimi wire types](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/wire/types.py), [Pi context calculation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/agent-session.ts), [Kilo context calculation](https://github.com/Kilo-Org/kilocode/blob/main/packages/tui/src/feature-plugins/sidebar/context.tsx), [ZCode context state](https://github.com/zai-org/ZCode/blob/main/docs/context-window-usage-state.md).

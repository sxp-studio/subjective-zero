// SPDX-License-Identifier: AGPL-3.0-only
// SZAI — provider wrapping, agent sessions, prompts, and the pluggable orchestration strategies.
//
// Providers are per-provider structs (`SZClaudeProvider` / `SZCodexProvider`) behind the `SZProvider`
// protocol, listed in `SZProviderRegistry`; shared spawn/stream/teardown lives in protocol-extension
// defaults over `SZProcess`. Orchestration is an `SZOrchestrating` strategy (Orchestration/):
// `SZProceduralDirectorStrategy` (deterministic / offline / CI) and `SZAgenticDirectorStrategy`
// (an LLM Director Agent that composes the procedural dispatch). Prompts are bundled markdown
// templates (`SZPrompts`). See docs/AI_PROVIDERS.md and docs/AGENT_ORCHESTRATION.md.
import SZCore

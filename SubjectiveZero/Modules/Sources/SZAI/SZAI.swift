// SPDX-License-Identifier: AGPL-3.0-only
// SZAI — provider wrapping, agent sessions, prompts, and the agent-graph orchestrator.
//
// Providers are per-provider structs (`SZClaudeProvider` / `SZCodexProvider`) behind the `SZProvider`
// protocol, listed in `SZProviderRegistry`; shared spawn/stream/teardown lives in protocol-extension
// defaults over `SZProcess`. Orchestration is the graph engine (Engine/): `SZGraphDirectorStrategy`
// drives validated agent packs through `SZThreadMachine` + `SZGraphEngine`, behind the
// `SZOrchestrating` seam (Orchestration/). Prompts are bundled markdown
// templates (`SZPrompts`) plus the packs' own template files. See docs/AI_PROVIDERS.md and
// docs/AGENT_ORCHESTRATION.md.
import SZCore

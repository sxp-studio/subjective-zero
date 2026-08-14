// SPDX-License-Identifier: AGPL-3.0-only
// SZAI — provider wrapping, agent sessions, prompts, and the agent-graph engine.
//
// Providers are per-provider structs (`SZClaudeProvider` / `SZCodexProvider`) behind the `SZProvider`
// protocol, listed in `SZProviderRegistry`; shared spawn/stream/teardown lives in protocol-extension
// defaults over `SZProcess`. Engine/ holds the traversal engine, the prompt assembler, and
// the query service; Agents/ loads and validates packs. The app's delivery layer owns
// transport. Prompts are bundled markdown templates (`SZPrompts`) plus the packs' own
// template files. See docs/AI_PROVIDERS.md and docs/AGENT_GRAPHS.md.
import SZCore

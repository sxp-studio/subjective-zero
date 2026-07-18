// SPDX-License-Identifier: AGPL-3.0-only
// The chat panel — a directed console into an agent, docked right of the viewport/editor combo.
// This is NOT a messaging UI: a chat turn drives a node's
// coding agent to edit + recompile that node, so the panel reads like a lab log addressed to one
// instrument. Signature: a scope header that names the node (SF Symbol + title), and a transcript of
// left-railed turns with a monospaced role eyebrow — no bubbles, no avatars.
//
// State-derived (docs/UI.md): it observes the injected @Observable SZStore and renders
// store.messages(for: scope); sending routes through `onSend` → host.sendChat (the same path as the
// `ui_send_chat` MCP tool). `scope` follows the editor's node selection (host-owned), or `.director`.
import AppKit
import Foundation
import ImageIO
import SwiftUI
import SZCore
import UniformTypeIdentifiers

public struct SZChatPanel: View {
    private let store: SZStore
    private let scope: SZChatScope
    private let tabs: [SZChatScope]
    private let project: SZProject?
    private let provider: String
    private let streaming: Bool                    // the active scope has a turn in flight → show the dots
    private let isRunning: Bool                    // a whole run is in flight → Project-tab Stop slot, sends disabled
    private let showTokenCounts: Bool              // View ▸ Show Token Counts — the usage caption under replies
    private let onStopRun: () -> Void              // the send slot's whole-run Stop (Project tab, while running)
    private let workingScopes: Set<String>         // scopes with a streaming turn → their tab dot pulses
    private let unreadScopes: Set<String>          // finished-unvisited scopes → static tab dot until visited
    private let needsInputScopes: Set<String>      // agents blocked on the USER → amber tab dot until resolved
    private let isQueued: (UUID) -> Bool           // message id → still waiting in the mailbox (queued chip)
    private let onSend: (String, [URL]) -> Void    // (message, attachment source URLs)
    private let onSelectScope: (SZChatScope) -> Void
    private let onCloseTab: (SZChatScope) -> Void
    private let onReorderTab: (SZChatScope, SZChatScope?) -> Void   // (dragged, before/nil=end) → reorder
    private let onClearTranscript: (SZChatScope) -> Void   // header trash — full reset (transcript + agent)
    private let canStopTurn: Bool                  // the active scope's turn is an interactive chat turn (stoppable)
    private let onCancelChatTurn: (SZChatScope) -> Void   // the working row's stop control
    private let scopeLocked: Bool                  // this node is agent-owned (implementing) → composer disabled

    // A host-drafted message awaiting the composer (context-menu suggestion). Applied once when it
    // matches the shown scope, then consumed — the handshake keeps re-renders from stomping edits.
    private let pendingDraft: SZComposerDraftInjection?
    private let onConsumePendingDraft: (UUID) -> Void

    // Pickable @mentions (host-computed from the live graph: @project, @all, one per node). Empty
    // = autocomplete off (previews/tests).
    private let mentionCandidates: [SZMentionCandidate]

    // The provider generation picker in the composer's bottom bar (host-mapped items + the same
    // intents `ui_set_provider` drives). Defaults keep the picker absent for callers that don't
    // wire it (previews/tests).
    private let generationPickerItems: [SZProviderGenerationPickerItem]
    private let onSetProvider: (String) -> Void
    private let onSetModel: (String) -> Void
    private let onSetReasoningEffort: (String) -> Void
    private let onSetFastMode: (Bool) -> Void
    private let onOpenProviderSetup: () -> Void

    // Composer control hover highlights + the locked-state timer start (view-local UI state).
    @State private var sendHover = false
    @State private var stopHover = false
    @State private var attachHover = false
    @State private var stopSince: Date?    // stamped when the composer locks → live "in flight" timer
    // Drafts are PER-TAB (Slack-style): each scope keeps its own unsent text, so switching tabs
    // doesn't carry the composer over, and a tab with unsent text shows a dot. Empty drafts are
    // nil'd out so the dot check is a simple presence test.
    @State private var draftsByScope: [String: SZComposerDraft] = [:]
    @State private var composerHeight: CGFloat = 22     // grows 1…6 lines, driven by the AppKit input
    @State private var pendingAttachments: [URL] = []   // staged-on-send: source URLs picked/dropped/pasted
    @State private var importing = false                // the + button's file picker is open
    @State private var dropTargeted = false             // a file drag is hovering the panel → show the drop hint
    @State private var dragKey: String?            // the node tab being dragged
    @State private var dragX: CGFloat?             // cursor x within the tab strip while dragging
    @State private var tabFrames: [String: CGRect] = [:]   // each tab's frame in the "tabstrip" space

    // Mention autocomplete: the live `@query` (nil = no session), the highlighted row, and whether
    // the user Esc-dismissed the list for this query. The relay lands a pick back in the buffer.
    @State private var mentionQuery: String?
    @State private var mentionHighlight = 0
    @State private var mentionDismissed = false
    @State private var mentionListHeight: CGFloat = 0   // measured → the above-the-card offset
    @State private var composerRelay = SZComposerCommandRelay()

    // The last injected draft — while the composer still holds it verbatim, the send button wears
    // a steady "act on me" ring; the first user edit or the send itself ends the emphasis.
    @State private var injectedDraft: SZComposerDraft?
    // A one-shot attention tint on the composer outline, fired when a draft is injected (you were
    // nudged here) — bright, then fades back to normal. 1 = full tint, animates to 0.
    @State private var attentionTint: Double = 0

    /// The active scope's draft — reads/writes the per-scope store, so every existing `draft`
    /// reference stays unchanged. Writing an empty draft drops the entry (keeps the dot map clean).
    private var draft: SZComposerDraft {
        get { draftsByScope[scope.key] ?? SZComposerDraft() }
        nonmutating set { draftsByScope[scope.key] = newValue.isEmpty ? nil : newValue }
    }
    private var draftBinding: Binding<SZComposerDraft> {
        Binding(get: { draft }, set: { draft = $0 })
    }
    /// A tab has unsent composer text → its dot.
    private func hasDraft(_ tab: SZChatScope) -> Bool {
        draftsByScope[tab.key]?.isEmpty == false
    }

    // User = the app's action blue; the coding agent = a warm orange echoing the node card's "coding"
    // state (`SZNodeStatusPill`) and the pulsing-orange streaming tab dot; the Director = the violet of
    // the flow/"then" edges it owns (`SZEdgeStyle.intentViolet`). Deliberate reuse of the app's semantic
    // palette so the panel reads as part of the same tool, not a bolt-on.
    fileprivate static let userColor = Color(red: 0.50, green: 0.64, blue: 1.0)   // fileprivate: SZChatTurnRow styles mention tokens with it
    private static let agentColor = Color(red: 0.96, green: 0.60, blue: 0.30)       // coding agent — warm orange, kin to the node's "coding" state
    private static let directorColor = SZEdgeStyle.intentViolet                     // Director = its own flow-edge violet
    private static let debugColor = Color(red: 0.70, green: 0.62, blue: 0.85)       // the debug chat agent — a muted "this is a tool" lilac

    public init(store: SZStore, scope: SZChatScope, tabs: [SZChatScope], project: SZProject?,
                provider: String, streaming: Bool,
                isRunning: Bool = false,
                showTokenCounts: Bool = false,
                onStopRun: @escaping () -> Void = {},
                workingScopes: Set<String> = [],
                unreadScopes: Set<String> = [],
                needsInputScopes: Set<String> = [],
                isQueued: @escaping (UUID) -> Bool = { _ in false },
                onSend: @escaping (String, [URL]) -> Void,
                onSelectScope: @escaping (SZChatScope) -> Void,
                onCloseTab: @escaping (SZChatScope) -> Void,
                onReorderTab: @escaping (SZChatScope, SZChatScope?) -> Void,
                onClearTranscript: @escaping (SZChatScope) -> Void = { _ in },
                canStopTurn: Bool = false,
                onCancelChatTurn: @escaping (SZChatScope) -> Void = { _ in },
                scopeLocked: Bool = false,
                mentionCandidates: [SZMentionCandidate] = [],
                pendingDraft: SZComposerDraftInjection? = nil,
                onConsumePendingDraft: @escaping (UUID) -> Void = { _ in },
                generationPickerItems: [SZProviderGenerationPickerItem] = [],
                onSetProvider: @escaping (String) -> Void = { _ in },
                onSetModel: @escaping (String) -> Void = { _ in },
                onSetReasoningEffort: @escaping (String) -> Void = { _ in },
                onSetFastMode: @escaping (Bool) -> Void = { _ in },
                onOpenProviderSetup: @escaping () -> Void = {}) {
        self.store = store
        self.scope = scope
        self.tabs = tabs
        self.project = project
        self.provider = provider
        self.streaming = streaming
        self.isRunning = isRunning
        self.showTokenCounts = showTokenCounts
        self.onStopRun = onStopRun
        self.workingScopes = workingScopes
        self.unreadScopes = unreadScopes
        self.needsInputScopes = needsInputScopes
        self.isQueued = isQueued
        self.onSend = onSend
        self.onSelectScope = onSelectScope
        self.onCloseTab = onCloseTab
        self.onReorderTab = onReorderTab
        self.onClearTranscript = onClearTranscript
        self.canStopTurn = canStopTurn
        self.scopeLocked = scopeLocked
        self.onCancelChatTurn = onCancelChatTurn
        self.mentionCandidates = mentionCandidates
        self.pendingDraft = pendingDraft
        self.onConsumePendingDraft = onConsumePendingDraft
        self.generationPickerItems = generationPickerItems
        self.onSetProvider = onSetProvider
        self.onSetModel = onSetModel
        self.onSetReasoningEffort = onSetReasoningEffort
        self.onSetFastMode = onSetFastMode
        self.onOpenProviderSetup = onOpenProviderSetup
    }

    /// The selected node (if the scope names one that still exists).
    private var node: SZNode? {
        if case .node(let id) = scope { return project?.graph.node(id: id) }
        return nil
    }

    private var isDebug: Bool { scope == .debug }

    // For a node the title IS the node (e.g. "Make Grayscale"); the agent acting on it is its Coding Agent.
    private var headerSubtitle: String {
        if isDebug { return "Debug chat agent · \(provider)" }
        return (node == nil ? "Coordinates the graph" : "Coding Agent") + " · \(provider)"
    }
    private var scopeName: String {
        if isDebug { return "the Debug Agent" }
        return node?.title.isEmpty == false ? node!.title : (node == nil ? "the Director Agent" : "this node")
    }

    public var body: some View {
        let messages = store.messages(for: scope)
        return VStack(spacing: 0) {
            tabBar
            contextLine
            Divider().overlay(Color.white.opacity(0.08))
            transcript(messages)
            composer
        }
        .background(Color(white: 0.12))
        // Drop a file ANYWHERE on this panel → attach it to the active transcript (AppKit catcher behind
        // the content; SwiftUI's .dropDestination on a parent only caught the transcript).
        .background(SZFileDropCatcher(onDrop: { urls, _ in appendAttachments(urls); return true },
                                      onTargeted: { dropTargeted = $0 }))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Self.userColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Self.userColor.opacity(0.06))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Self.userColor)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        // Injection handshake: apply a pending host draft when it matches the shown scope —
        // on appear (the injection usually opens the panel), on a new injection, and on a tab
        // switch landing on the target scope.
        .onAppear(perform: applyPendingDraft)
        .onChange(of: pendingDraft?.id) { applyPendingDraft() }
        .onChange(of: scope) { applyPendingDraft() }
    }

    private func applyPendingDraft() {
        guard let injection = pendingDraft, injection.scope == scope else { return }
        onConsumePendingDraft(injection.id)   // consumed either way — a skipped nudge must not linger
        guard injection.replacesNonEmpty || draft.isEmpty else { return }
        draft = injection.draft
        injectedDraft = injection.draft
        flashComposerAttention()
    }

    /// A transient accent tint on the composer outline to catch the eye when you land here (a
    /// beacon click / suggestion): bright on, then fades back to normal — no persistent chrome.
    /// The reset is deferred one run-loop tick: setting 1 then animating to 0 in the SAME turn is
    /// coalesced by SwiftUI (the bright state never paints — it animates 0→0), so the "on" must
    /// commit first, then the fade runs on the next tick.
    private func flashComposerAttention() {
        attentionTint = 1
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 1.1)) { attentionTint = 0 }
        }
    }

    /// The injected draft still sits verbatim in the composer → the send button pulses "act on me"
    /// (V1 ruling). Any user edit or the send itself ends it.
    private var sendEmphasized: Bool {
        injectedDraft != nil && injectedDraft == draft && !draft.isEmpty
    }

    // Classic tabs: rounded-top rectangles sitting on a darker strip; the active tab is filled
    // to match the content below (looks connected), inactive tabs recede; node tabs carry a close ✕.
    // Drag any tab to reorder it (VSCode-style): a blue insertion bar tracks the drop slot and the tab
    // lands there on release. The Director is movable too (it just can't be closed).
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.key) { tab in tabView(tab) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .coordinateSpace(.named(Self.tabStrip))
            .onPreferenceChange(SZTabFramesKey.self) { tabFrames = $0 }
            .overlay(alignment: .topLeading) { insertionBar }
            .animation(.easeInOut(duration: 0.18), value: tabs.map(\.key))
        }
        .background(Color(white: 0.08))
    }

    /// The blue insertion bar shown at the drop slot during a drag.
    @ViewBuilder
    private var insertionBar: some View {
        if let x = insertionLineX, let probe = tabFrames.values.first {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(red: 0.26, green: 0.59, blue: 1.0))
                .frame(width: 2.5, height: probe.height)
                .offset(x: x - 1.25, y: probe.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Insertion slot (0…tabs.count) under the cursor: how many tabs sit left of the cursor's x.
    private var insertionGap: Int? {
        guard dragKey != nil, let x = dragX else { return nil }
        return tabs.reduce(0) { acc, t in (tabFrames[t.key].map { $0.midX < x } ?? false) ? acc + 1 : acc }
    }

    /// X (in tab-strip space) for the insertion bar: the leading edge of the slot's tab, or past the last.
    private var insertionLineX: CGFloat? {
        guard let g = insertionGap else { return nil }
        if g < tabs.count, let f = tabFrames[tabs[g].key] { return f.minX - 3 }
        if let last = tabs.last, let f = tabFrames[last.key] { return f.maxX + 3 }
        return nil
    }

    // Every tab is draggable (the Director too). Normal-priority drag so the ✕ button still wins its
    // taps; a no-move release is treated as a tap → select.
    private func tabView(_ tab: SZChatScope) -> some View {
        tabChip(tab)
            .opacity(dragKey == tab.key ? 0.45 : 1)        // the lifted tab dims while dragging
            .zIndex(dragKey == tab.key ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.tabStrip))
                    .onChanged { v in
                        if dragKey == nil { withAnimation(.easeOut(duration: 0.12)) { dragKey = tab.key } }
                        dragX = v.location.x
                    }
                    .onEnded { _ in endDrag(tab) }
            )
            .simultaneousGesture(TapGesture().onEnded { if dragKey == nil { onSelectScope(tab) } })
    }

    /// Commit (or cancel) a tab drag. A release with no real drag is treated as a tap → select.
    private func endDrag(_ tab: SZChatScope) {
        defer { withAnimation(.easeInOut(duration: 0.18)) { dragKey = nil }; dragX = nil }
        guard dragKey != nil else { onSelectScope(tab); return }
        guard let g = insertionGap else { return }
        let before: SZChatScope? = g < tabs.count ? tabs[g] : nil
        if before?.key == tab.key { return }                          // dropped on its own leading edge
        if let cur = tabs.firstIndex(of: tab), g == cur + 1 { return } // dropped just right of itself
        withAnimation(.easeInOut(duration: 0.18)) { onReorderTab(tab, before) }
    }

    private func tabChip(_ tab: SZChatScope) -> some View {
        let active = tab.key == scope.key
        let tabNode = nodeFor(tab)
        let symbol = tab == .debug ? "ladybug.fill"
            : tab == .director ? "eyeglasses"   // the Director's oversight glyph, matching its transcript
            : (tabNode?.sfSymbol ?? "sparkles")
        // Leading glyph carries the tab's role color (same mapping as the transcript accents), so a tab
        // and its messages read as one identity; the label text keeps the active/inactive weight cue.
        let accent = tab == .debug ? Self.debugColor
            : tab == .director ? Self.directorColor
            : Self.agentColor
        let label: String = {
            if tab == .director { return "Director" }   // the Director Agent — orchestrates the graph
            if tab == .debug { return "Debug" }
            return tabNode.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "node"
        }()
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent.opacity(active ? 1 : 0.75))
            Text(label).font(.system(size: 11, weight: active ? .semibold : .regular)).lineLimit(1)
            tabActivityDot(tab)
            if tab != .director {
                Button { onCloseTab(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .foregroundStyle(active ? .primary : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 150)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                .fill(active ? Color(white: 0.12) : Color(white: 0.15)))
        .contentShape(Rectangle())
        .background(GeometryReader { g in        // report this tab's frame for drag hit-testing
            Color.clear.preference(key: SZTabFramesKey.self,
                                   value: [tab.key: g.frame(in: .named(Self.tabStrip))])
        })
    }

    /// A tab's activity signal, sharing the node-card status palette (`SZNodeStatus.color`) so a
    /// tab dot and its node's pill read as the same state: PULSING ORANGE while the agent streams a
    /// turn (coding); GOLD while it's blocked on the user (needs input — persists even on the
    /// visited tab, until the state resolves); a static GREEN dot once a turn finished off-screen,
    /// until visited (ready/unread) — so a run's node tabs finishing at different times stay legible.
    @ViewBuilder
    private func tabActivityDot(_ tab: SZChatScope) -> some View {
        if workingScopes.contains(tab.key) {
            // Render-server pulse (SZPulsingOpacity): a TimelineView(.animation) here was a standing
            // per-display-frame SwiftUI update for the whole streaming turn. Half-period π/4 keeps
            // the old sin(t·4) cadence.
            SZPulsingOpacity(range: 0.35...0.95, halfPeriod: 0.79) {
                Circle().fill(SZNodeStatus.building.color)
                    .frame(width: 5, height: 5)
            }
        } else if needsInputScopes.contains(tab.key) {
            Circle().fill(SZNodeStatus.needsInput.color).frame(width: 5, height: 5)
                .help("This agent is waiting on your input")
        } else if unreadScopes.contains(tab.key) {
            Circle().fill(SZNodeStatus.ready.color).frame(width: 4.5, height: 4.5)
        } else if tab.key != scope.key, hasDraft(tab) {
            // Unsent text waiting in that tab (not the one you're looking at) — a hollow dot, so it
            // reads as "your draft" distinct from the filled "unread reply".
            Circle().strokeBorder(Self.userColor.opacity(0.8), lineWidth: 1.2).frame(width: 5.5, height: 5.5)
        }
    }

    private static let tabStrip = "sz-chat-tabstrip"

    private var contextLine: some View {
        HStack {
            Text(headerSubtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Clear = a FULL reset (transcript + the agent's session — the host side documents why
            // they go together). Hidden on an empty tab; disabled while a turn streams.
            if !store.messages(for: scope).isEmpty {
                Button { onClearTranscript(scope) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(streaming)
                .opacity(streaming ? 0.35 : 1)
                .help("Clear transcript & reset agent")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 9)
    }

    private func nodeFor(_ s: SZChatScope) -> SZNode? {
        if case .node(let id) = s { return project?.graph.node(id: id) }
        return nil
    }

    private func transcript(_ messages: [SZChatMessage]) -> some View {
        // Computed once per transcript render, shared by every row's tombstone check — it changes
        // only on graph edits, which is exactly when mention tombstones must re-render.
        let liveNodeIDs = Set(project?.graph.nodes.map(\.id) ?? [])
        return ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) {
                            turn(for: $0, isLast: $0.id == messages.last?.id, liveNodeIDs: liveNodeIDs)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)   // scroll anchor
                    }
                    .padding(14)
                }
            }
            .onChange(of: messages.last?.id) { scrollToBottom(proxy) }
            // Streaming growth: compare the cheap count (not the whole string) and pin WITHOUT
            // animation — at flush cadence a hard bottom-pin reads as ticker tape, steadier than
            // an interruptible 0.15s animation restarted per flush. The animated scroll stays for
            // new-message transitions only (above).
            .onChange(of: messages.last?.text.count) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(isDebug
                 ? "Debug chat — message a plain provider-backed agent. Attach files to test attachments."
                 : (node == nil
                    ? "Message the Director Agent to plan or adjust the graph."
                    : "Ask \(scopeName)'s Coding Agent to change this node."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 48)
    }

    /// One transcript row, packaged into value-only props for an `.equatable()` skip (the
    /// `SZNodeCanvasContentView` idiom): a streaming flush changes only the growing LAST row's
    /// `message`, so every older row fails fast on `==` and never re-runs its body — including its
    /// markdown parse. A graph edit changes `liveNodeIDs`, correctly re-rendering all rows' mention
    /// tombstones.
    private func turn(for message: SZChatMessage, isLast: Bool, liveNodeIDs: Set<SZNodeID>) -> some View {
        let isUser = message.role == .user
        // The Director's identity reads the same everywhere: its own replies in the Director tab AND
        // the messages it posts into a node's tab → one accent + symbol, so the violet "director agent" never
        // gets mistaken for the orange "coding agent" whose tab it's speaking in.
        let isDebugReply = isDebug && !isUser   // the debug chat agent's reply (its own tab)
        let isDirector = !isDebugReply && (message.role == .director || (message.role == .assistant && node == nil))
        return SZChatTurnRow(
            message: message,
            // Dots = this turn is still in flight (works for codex's preamble-then-tools order, not
            // just "text empty"): the in-flight assistant turn is always the last message.
            working: streaming && isLast && message.role == .assistant,
            // Queued rides in as a VALUE (not the closure) so the row's `.equatable()` skip keeps
            // working: the chip flips exactly when the prop flips.
            queued: isUser && isQueued(message.id),
            showTokenCounts: showTokenCounts,
            accent: isUser ? Self.userColor
                : (isDebugReply ? Self.debugColor : (isDirector ? Self.directorColor : Self.agentColor)),
            label: isUser ? "you"
                : (isDebugReply ? "debug agent" : (isDirector ? "director agent" : "coding agent")),
            // Symbol next to the label (accessibility — not color-only): the Director's `eyeglasses`
            // (matching its tab), the node's own sfSymbol for its Coding Agent, a person for the user.
            symbol: isUser ? "person.fill"
                : (isDebugReply ? "ladybug.fill" : (isDirector ? "eyeglasses" : (node?.sfSymbol ?? "sparkles"))),
            liveNodeIDs: liveNodeIDs)
            .equatable()
    }

    // The Codex-style input card: a rounded two-row surface floating on the panel background —
    // text on top, controls on a bottom bar. (A project context chip below the card was tried and
    // cut — it duplicated the window title and wasn't interactive.)
    private static let cardFill = Color(white: 0.16)
    private static let cardStroke = Color.white.opacity(0.12)
    private static let cardCornerRadius: CGFloat = 12

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Locked (a run/turn in flight, or the node is agent-owned): the whole input is REPLACED
            // by a centered Stop + live timer — unambiguous that you can't type, and the Stop reads
            // as the one live control. (Text can't merely be .disabled(): AppKit's NSTextView ignores
            // it.) The per-tab draft is preserved for when the lock lifts.
            if inputLocked {
                lockedComposer
            } else {
                normalComposer
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Self.cardCornerRadius).fill(Self.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Self.cardCornerRadius)
            .strokeBorder(Self.cardStroke, lineWidth: 0.75))
        // Transient attention tint: a bright accent outline on injection that fades to nothing.
        .overlay(RoundedRectangle(cornerRadius: Self.cardCornerRadius)
            .strokeBorder(Self.userColor, lineWidth: 1.5)
            .opacity(attentionTint * 0.9))
        // The autocomplete floats just above the card (Slack-style, anchored to the composer — not
        // the caret): measured, then offset so its bottom sits 6pt above the card's top (an
        // alignment-guide shift rendered ON the card in practice — measured offset is exact).
        .overlay(alignment: .topLeading) {
            if mentionListVisible {
                SZMentionAutocompleteView(
                    candidates: filteredMentionCandidates,
                    highlightIndex: mentionHighlight,
                    onHighlight: { mentionHighlight = $0 },
                    onPick: { composerRelay.insertMention?($0) })
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { mentionListHeight = $0 }
                    .offset(y: -(mentionListHeight + 6))
                    .opacity(mentionListHeight == 0 ? 0 : 1)   // no first-frame flash at the wrong spot
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { appendAttachments(urls) }
        }
        // Fallback timer start, stamped when the lock begins (whole run / split-merge, which have no
        // in-flight message to read a real start from). Streaming turns prefer the message timestamp
        // (see `runningSince`), so this is only a fallback and stays stable across tab switches.
        .onChange(of: inputLocked) { _, locked in stopSince = locked ? Date() : nil }
        .onAppear { if inputLocked, stopSince == nil { stopSince = Date() } }
        // (Panel-wide drop is handled on the whole chat panel in `body`; the composer field also takes
        //  drops directly over itself via SZComposerTextView.)
    }

    /// The everyday composer: pending-attachment tray, the text field, and the bottom bar (attach ·
    /// recipient hint · model picker · send). Shown only when NOT locked, so the action is always
    /// send — the Stop lives in `lockedComposer`.
    @ViewBuilder
    private var normalComposer: some View {
        if !pendingAttachments.isEmpty {
            // Pending tray: a preview per staged file (image thumbnail / generic chip), each removable.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pendingAttachments, id: \.self) { url in
                        SZAttachmentChipView(filename: url.lastPathComponent, url: url,
                                             isImage: szIsImageFile(url),
                                             byteCount: szFileByteCount(url),
                                             onRemove: { removeAttachment(url) })
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        // AppKit-backed so a dropped/pasted FILE attaches instead of inserting its path/name as text.
        SZComposerTextView(draft: draftBinding, height: $composerHeight,
                           placeholder: "Message \(scopeName)…",
                           onSubmit: send, onAttach: { appendAttachments($0) },
                           onMentionSession: mentionSessionChanged,
                           onMentionCommand: handleMentionCommand,
                           relay: composerRelay)
            .frame(height: composerHeight)
        HStack(spacing: 8) {
            Button { importing = true } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(attachHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .scaleEffect(attachHover ? 1.1 : 1)
            }
            .buttonStyle(.plain)
            .trackingHover($attachHover)
            .help("Attach files")
            // The recipient line appears ONLY when a leading @mention reroutes the draft OFF this tab
            // (typing in a tab addresses that tab's agent — showing that is just noise).
            if let rerouted = reroutedRecipientLabel {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(rerouted).lineLimit(1)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if !generationPickerItems.isEmpty {
                SZProviderGenerationPickerView(
                    items: generationPickerItems,
                    onSetProvider: onSetProvider,
                    onSetModel: onSetModel,
                    onSetReasoningEffort: onSetReasoningEffort,
                    onSetFastMode: onSetFastMode,
                    onOpenProviderSetup: onOpenProviderSetup)
            }
            // The Stop rides NEXT TO send while a run / this scope's turn is in flight — the input
            // stays live (a send queues), but stopping is always one click, on every tab.
            if let stop = activeStop {
                stopButton(stop.action, help: stop.help)
            }
            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(canSend ? Self.userColor : Color.secondary.opacity(0.5))
                .brightness(sendHover && canSend ? 0.12 : 0)
                .scaleEffect(sendHover && canSend ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .trackingHover($sendHover)
        .overlay {
            if sendEmphasized {   // steady ring while the injected draft is unacted-on
                Circle()
                    .stroke(Self.userColor.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(1.18)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The structurally-locked state (a node mid split/merge — the one case the input still tears
    /// down): centered status + live timer, plus a Stop when a run is also in flight. Runs and
    /// streaming turns no longer come through here — their Stop rides the normal composer.
    private var lockedComposer: some View {
        HStack(spacing: 12) {
            if let stop = activeStop {
                stopButton(stop.action, help: stop.help)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(lockTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let since = runningSince {
                    SZElapsedLabel(since: since)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .center)
    }

    /// When the in-flight work started, for the locked composer's live timer. A streaming turn reads
    /// its own in-flight assistant message's start (accurate, and survives tab switches — the same
    /// source the transcript's working row uses); a whole run / split-merge (no in-flight message on
    /// this tab) falls back to `stopSince`, stamped when the lock began.
    private var runningSince: Date? {
        if streaming, let last = store.messages(for: scope).last,
           last.role == .assistant, last.duration == nil {
            return last.timestamp
        }
        return stopSince
    }

    /// The current stoppable action + its tooltip: the whole run (any tab, while running) or this
    /// scope's own streaming turn. nil when the lock has no stoppable control.
    private var activeStop: (action: () -> Void, help: String)? {
        if isRunning { return (onStopRun, "Stop the run — nodes already implemented stay") }
        if canStopTurn, streaming {
            return ({ onCancelChatTurn(scope) }, "Stop this turn — the agent keeps its session; partial reply stays")
        }
        return nil
    }

    /// A short title for the in-flight state: a whole run reads the same on every tab; an individual
    /// conversation turn just says the agent is working.
    private var lockTitle: String {
        if isRunning { return "Run in flight" }
        switch scope {
        case .director: return "Thinking…"
        case .node: return "Working…"
        case .debug: return "Replying…"
        }
    }

    // MARK: - Mention autocomplete

    /// Prefix matches first, then contains — case-insensitive on the candidate title. An empty
    /// query (bare "@") lists everything.
    private var filteredMentionCandidates: [SZMentionCandidate] {
        guard let query = mentionQuery, !query.isEmpty else { return mentionCandidates }
        let q = query.lowercased()
        let prefix = mentionCandidates.filter { $0.title.lowercased().hasPrefix(q) }
        let contains = mentionCandidates.filter {
            !$0.title.lowercased().hasPrefix(q) && $0.title.lowercased().contains(q)
        }
        return prefix + contains
    }

    private var mentionListVisible: Bool {
        // Never over a locked composer: the text field (and its coordinator) is torn down when
        // inputLocked, but a `@mention` session in flight at that instant leaves `mentionQuery` set.
        !inputLocked && mentionQuery != nil && !mentionDismissed && !filteredMentionCandidates.isEmpty
    }

    private func mentionSessionChanged(_ query: String?) {
        guard query != mentionQuery else { return }
        mentionQuery = query
        mentionHighlight = 0
        mentionDismissed = false   // a changed query re-opens an Esc-dismissed list
    }

    /// Keyboard routed from the text view while a session is live. Returning false lets the key
    /// fall through (Return with nothing to pick still sends).
    private func handleMentionCommand(_ command: SZMentionCommand) -> Bool {
        guard mentionListVisible else { return false }
        let candidates = filteredMentionCandidates
        switch command {
        case .up: mentionHighlight = max(0, mentionHighlight - 1)
        case .down: mentionHighlight = min(candidates.count - 1, mentionHighlight + 1)
        case .commit: composerRelay.insertMention?(candidates[min(mentionHighlight, candidates.count - 1)])
        case .dismiss: mentionDismissed = true
        }
        return true
    }

    private var canSend: Bool {
        !draft.isEmpty || !pendingAttachments.isEmpty
    }

    /// Text input is inert only while the node is structurally owned (mid-split/merge — it may not
    /// exist when the op settles). Every other busy state queues instead of locking: the Stop for
    /// a run/streaming turn renders ALONGSIDE the live composer (`activeStop` in the bottom bar),
    /// and a send while something streams simply queues with a chip on its bubble.
    private var inputLocked: Bool { scopeLocked }

    /// The action slot's Stop — orange, pulsing, and hover-reactive. Stays full-strength while the
    /// rest of the composer is locked/greyed, so it reads as the one live control.
    private func stopButton(_ action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .brightness(stopHover ? 0.12 : 0)
                .scaleEffect(stopHover ? 1.1 : 1)
                .modifier(SZStopPulse())
        }
        .buttonStyle(.plain)
        .trackingHover($stopHover)
        .help(help)
    }

    /// The recipient label ONLY when a leading @mention reroutes the draft OFF the current tab —
    /// nil when the message would go to this tab's own agent (showing that is redundant noise).
    private var reroutedRecipientLabel: String? {
        let recipient = SZChatRouting.resolveRecipient(message: draft.canonicalText, activeScope: scope)
        guard recipient != scope else { return nil }
        switch recipient {
        case .director: return "Director Agent"
        case .debug: return "Debug Agent"
        case .node(let id):
            let title = project?.graph.node(id: id)?.title
            return "\(title?.isEmpty == false ? title! : "node") · Coding Agent"
        }
    }

    private func send() {
        // The wire form: mention markup inline — the host parses it for routing/expansion and
        // stores it canonically in the transcript.
        let message = draft.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !pendingAttachments.isEmpty else { return }
        onSend(message, pendingAttachments)
        draft = SZComposerDraft()
        injectedDraft = nil
        pendingAttachments = []
    }

    /// Append picked/dropped/pasted file URLs, skipping ones already staged (de-dupe by path).
    private func appendAttachments(_ urls: [URL]) {
        for url in urls where !pendingAttachments.contains(where: { $0.path == url.path }) {
            pendingAttachments.append(url)
        }
    }

    private func removeAttachment(_ url: URL) { pendingAttachments.removeAll { $0 == url } }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private static let bottomID = "sz-chat-bottom"
}

/// Collects each chat tab's frame (in the tab-strip coordinate space) so the drag-reorder can
/// hit-test the cursor against tab midpoints and place the insertion bar.
private struct SZTabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// One transcript turn, `.equatable()`-gated by the panel. VALUE-ONLY stored props — adding a
/// closure or reference prop here silently breaks the `==` skip (every row would re-render per
/// streaming flush again), so anything the row can DO stays on the panel and anything it RENDERS
/// arrives as a compared value. Row identity is the message id (ForEach), so `SZThinkingView`'s
/// `@State expanded` survives streaming re-renders of the growing row.
private struct SZChatTurnRow: View, Equatable {
    let message: SZChatMessage
    let working: Bool               // this turn is still in flight → dots + live elapsed timer
    let queued: Bool                // user message still waiting in the mailbox → queued chip
    let showTokenCounts: Bool
    let accent: Color
    let label: String
    let symbol: String
    let liveNodeIDs: Set<SZNodeID>  // mention-tombstone check; changes only on graph edits

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(accent.opacity(0.8)).frame(width: 2)   // the left rail — the signature
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                }
                .foregroundStyle(accent)
                if !message.thinking.isEmpty {
                    SZThinkingView(text: message.thinking)   // collapsible activity + reasoning trace
                }
                if !message.text.isEmpty {
                    markdownText(message.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isUser ? .primary : Color.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.attachments.isEmpty {
                    SZAttachmentRow(attachments: message.attachments)   // thumbnails / file chips, read-only
                }
                if queued {
                    // Waiting in the mailbox — delivers when the agent frees (a run holds it, or an
                    // earlier message is still being answered). Breathes softly while it waits and
                    // fades out the moment delivery starts.
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text("queued")
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .modifier(SZQueuedBreathe())
                    .transition(.opacity)
                }
                if working {
                    HStack(spacing: 7) {   // dots + live elapsed timer while the turn runs
                        SZTypingIndicator()
                        SZElapsedLabel(since: message.timestamp)
                        // No inline stop here — the composer's send slot IS the action slot
                        // (send / stop-turn / stop-run); a second stop that wanders is worse.
                    }
                } else if let duration = message.duration, message.role == .assistant {
                    // Final time + tokens, kept below the reply. Tokens are opt-in (View ▸ Show
                    // Token Counts), and not every CLI reports usage.
                    let tokens = showTokenCounts ? message.usage.map {
                        " · \(szFormatTokensCompact($0.inputTokens)) in / \(szFormatTokensCompact($0.outputTokens)) out"
                    } ?? "" : ""
                    Text("Worked for \(szFormatDurationCompact(duration))\(tokens)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Drives the queued chip's fade-in/out (the .transition above needs an animated change).
        .animation(.easeInOut(duration: 0.35), value: queued)
    }

    /// Render an agent reply as **inline** Markdown — bold / italic / inline `code` / links — preserving
    /// line breaks. User text stays literal (the user typed it) apart from mention TOKENS, which
    /// render styled (see `mentionStyledText`). Block-level Markdown (fenced ```code``` blocks,
    /// bullet/numbered lists, headers) is NOT laid out — SwiftUI `Text` can't; that's a separate
    /// follow-up. Falls back to plain text if the source doesn't parse.
    private func markdownText(_ raw: String) -> Text {
        if isUser { return mentionStyledText(raw) }
        guard var attributed = try? AttributedString(markdown: raw, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible))
        else { return Text(raw) }
        // Inline `code` runs carry only `.code` presentation intent, no explicit font — SwiftUI renders
        // them monospaced but the body 12.5pt makes them read visibly LARGER than the surrounding prose,
        // since SF Mono's x-height/stroke run heavier than SF Pro at the same point size. Pin code runs a
        // notch down (~0.88×, the usual inline-code ratio) so they sit level with the 12.5pt body text.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 11, design: .monospaced)
        }
        return Text(attributed)
    }

    /// A user message with its stored mention markup rendered as accent tokens — the display frozen
    /// at send time (what the user actually said); a mention whose node has since been deleted dims
    /// and strikes through (the tombstone). Plain messages pass through literal.
    private func mentionStyledText(_ raw: String) -> Text {
        let segments = SZMentionMarkup.parse(raw)
        guard segments.contains(where: { if case .mention = $0 { true } else { false } }) else {
            return Text(raw)
        }
        return segments.reduce(Text("")) { result, segment in
            switch segment {
            case .text(let t):
                return result + Text(t)
            case .mention(let target, let display):
                let deleted: Bool = {
                    if case .node(let id) = target { return !liveNodeIDs.contains(id) }
                    return false
                }()
                let token = Text("@\(display)").fontWeight(.medium)
                return result + (deleted
                    ? token.strikethrough().foregroundColor(.secondary)
                    : token.foregroundColor(SZChatPanel.userColor))
            }
        }
    }
}

/// A small "agent is working" pulse shown while an assistant turn is still empty — echoes the
/// blinking status pill the node editor uses during a run.
private struct SZTypingIndicator: View {
    // repeatForever animations run on the render server — zero main-thread frames, unlike the
    // TimelineView(.animation) this replaces, which re-entered SwiftUI every display frame for the
    // whole turn. The per-dot delay keeps the traveling-wave feel of the old sin(t·4.2 − i·0.9).
    @State private var bright = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(bright ? 0.9 : 0.28)
                    .scaleEffect(bright ? 1.0 : 0.82)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.21), value: bright)
            }
        }
        .onAppear { bright = true }
    }
}

/// Live elapsed time for an in-flight turn, ticking each second from the turn's start.
private struct SZElapsedLabel: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(szFormatDuration(context.date.timeIntervalSince(since)))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Clock-style elapsed time for the LIVE ticking timer: zero-padded `mm:ss` (`00:07`, `01:23`),
/// growing to `h:mm:ss` past an hour — stable-width, stopwatch feel.
private func szFormatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

/// Compact duration for PROSE (the final "Worked for …" label): `12s` under a minute, else `1m 5s` —
/// reads as English in a sentence, where the clock format ("00:03") looks like a bolted-on readout.
private func szFormatDurationCompact(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval.rounded()))
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

/// Compact token count for the usage readout next to the duration: `393`, `21.5k`, `1.2M`.
/// The k→M boundary sits at 999,950 so `%.1f` can't round a k-value up to "1000.0k".
/// `internal` (not private) for the unit tests.
func szFormatTokensCompact(_ tokens: Int) -> String {
    switch tokens {
    case ..<1000: return "\(tokens)"
    case ..<999_950: return String(format: "%.1fk", Double(tokens) / 1000)
    default: return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}

/// Whether a file should preview as an image (by its extension's UTType) — the composer's pending
/// tray, pre-staging. UI-side file inspection: `SZChatAttachment` (SZCore) stays a plain record.
private func szIsImageFile(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
}

/// The file's size in bytes, or nil if it can't be stat'd (pending-tray preview).
private func szFileByteCount(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
}

/// A read-only row of attachment previews under a chat turn (the chips reuse `SZAttachmentChipView`).
private struct SZAttachmentRow: View {
    let attachments: [SZChatAttachment]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    SZAttachmentChipView(filename: a.filename, url: a.url, isImage: a.isImage, byteCount: a.byteCount)
                }
            }
        }
    }
}

/// One attachment preview — an image thumbnail or a generic file chip (icon + name + size). Shows a
/// removable ✕ when `onRemove` is provided (the composer's pending tray); read-only in the transcript.
private struct SZAttachmentChipView: View {
    let filename: String
    let url: URL
    let isImage: Bool
    let byteCount: Int?
    var onRemove: (() -> Void)? = nil

    @State private var removeHover = false
    @State private var cursorPushed = false   // tracked so we always pop (even if the chip is removed mid-hover)

    private var sizeLabel: String? {
        byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// Push/pop the pointing-hand cursor exactly once per hover, balanced so a chip torn down while
    /// hovered (remove ✕ / send clears the tray / scope switch) still pops and never leaves it stuck.
    private func setCursorPushed(_ pushed: Bool) {
        guard pushed != cursorPushed else { return }
        cursorPushed = pushed
        if pushed { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    var body: some View {
        Group {
            if isImage {
                SZAttachmentThumbnail(url: url, size: 64)
                    .help(filename)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if let sizeLabel {
                            Text(sizeLabel).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 10)
                .frame(maxWidth: 180, minHeight: 64, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.18)))
            }
        }
        // Click opens the file in its default app; the hand cursor signals it's clickable.
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help(filename)
        .onHover { hovering in setCursorPushed(hovering) }
        .onDisappear { setCursorPushed(false) }   // a chip removed/scrolled away while hovered must still pop
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        // Hover → red circle so it reads as a clickable remove control.
                        .background(Circle().fill(removeHover ? Color.red.opacity(0.95) : Color.black.opacity(0.62)))
                        .scaleEffect(removeHover ? 1.12 : 1.0)
                }
                .buttonStyle(.plain)
                .help("Remove")
                .contentShape(Circle())
                .onHover { removeHover = $0 }   // red highlight; the chip-level hover owns the cursor
                .animation(.easeOut(duration: 0.1), value: removeHover)
                .padding(4)   // inset so the scroll view doesn't clip it (the old negative offset did)
            }
        }
    }
}

/// Loads a small DOWNSAMPLED thumbnail off the file at `url` (cached in @State), filling a square frame.
/// Downsampling via ImageIO avoids decoding a full-resolution attachment (e.g. a multi-MB camera frame)
/// into a 64pt box — cheaper decode + far less memory than `NSImage(contentsOf:)`.
private struct SZAttachmentThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
        .task(id: url) { image = Self.downsampled(url: url, maxPixel: size * 2) }
    }

    /// A thumbnail no larger than `maxPixel` on its long edge (≈ @2x of the display box).
    private static func downsampled(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A collapsible "thinking" disclosure for an assistant turn — the agent's tool activity + reasoning
/// trace, hidden by default behind a chevron so the final reply stays front and center.
private struct SZThinkingView: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Thinking")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .textCase(.uppercase)
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
        }
    }
}

/// The active Stop button's "a run is in flight" pulse — a quiet opacity breathe, no glow.
/// Runs on the render server (SZPulsingOpacity); half-period π/3 keeps the old sin(t·3) cadence.
private struct SZStopPulse: ViewModifier {
    func body(content: Content) -> some View {
        SZPulsingOpacity(range: 0.55...1.0, halfPeriod: 1.05) { content }
    }
}

/// The queued chip's soft breathe — the Stop pulse's calmer sibling (slower, dimmer): it says
/// "waiting its turn", not "act now".
private struct SZQueuedBreathe: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 1.6)
            content.opacity(0.45 + 0.4 * phase)
        }
    }
}

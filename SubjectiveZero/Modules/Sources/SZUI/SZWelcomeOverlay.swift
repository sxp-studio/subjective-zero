// SPDX-License-Identifier: AGPL-3.0-only
// The welcome / home surface — a full-window split launcher (NOT a sheet, so it never contends with
// the provider sheet, Open/Save panels, or a TCC permission prompt on the same window). It is the
// LAUNCH view: shown before any project loads, so a cold launch never touches the camera/mic until
// the user actually opens a project.
//
//   • Left half — the node editor's signature dotted grid + cursor-trail effect (reused verbatim, at
//     a brighter glyph tone), the app identity, the community CTAs, and the "show at startup" toggle.
//   • Right half — plain dark panel: recent projects (with a Clear pill) or a "No projects yet"
//     empty state, then New / Open.
//
// Pure SZUI: everything project/host-specific arrives as injected values + closures (the panel seam),
// including the GitHub/Discord brand glyphs (their symbolsets live in the app bundle, not SZUI's).
import AppKit
import SwiftUI

/// One recent project row — a pure view-model the host maps from its `.subz` paths (SZUI never
/// touches URLs/the filesystem).
public struct SZWelcomeRecent: Identifiable, Equatable, Sendable {
    public let id: String       // the full path (also the open key)
    public let name: String     // display name (file name sans extension)
    public let path: String     // full path, shown dimmed under the name
    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// The welcome window's palette. Orange is the single bold accent (spent on the Star CTA + its star
/// line); everything else stays in the editor's neutral dark tones.
enum SZWelcomeStyle {
    static let accent      = Color(red: 0.910, green: 0.454, blue: 0.231)  // #E8743B "Ember"
    static let accentSoft  = Color(red: 0.957, green: 0.706, blue: 0.561)  // #F4B48F
    static let text        = Color(white: 0.925)
    static let btnFill     = Color(white: 0.10)
    static let btnHover    = Color(white: 0.135)
    // The primary action reads as primary via a SOLID warm ember fill + an ember border (not a
    // translucent tint), with the same white label/icon as every other button — one text color throughout.
    static let primaryFill      = Color(red: 0.290, green: 0.190, blue: 0.120)  // solid ember-over-dark
    static let primaryFillHover = Color(red: 0.350, green: 0.235, blue: 0.150)
    static let hair        = Color.white.opacity(0.10)
    static let hairSoft    = Color.white.opacity(0.06)
    /// Brighter than the node editor's 0.16 so the trail reads as a foreground flourish here.
    static let trailGlyphOpacity = 0.42
}

public struct SZWelcomeOverlay: View {
    private let versionText: String
    private let taglines: [String]
    private let recents: [SZWelcomeRecent]
    private let showAtStartup: Bool
    private let githubIcon: Image
    private let discordIcon: Image
    private let onOpenRecent: (String) -> Void
    private let onNewProject: () -> Void
    private let onOpenProject: () -> Void
    private let onClearRecents: () -> Void
    private let onStarGitHub: () -> Void
    private let onJoinDiscord: () -> Void
    private let onOpenWebsite: () -> Void
    private let onSetShowAtStartup: (Bool) -> Void
    private let onClose: () -> Void

    public init(versionText: String,
                taglines: [String],
                recents: [SZWelcomeRecent],
                showAtStartup: Bool,
                githubIcon: Image,
                discordIcon: Image,
                onOpenRecent: @escaping (String) -> Void,
                onNewProject: @escaping () -> Void,
                onOpenProject: @escaping () -> Void,
                onClearRecents: @escaping () -> Void,
                onStarGitHub: @escaping () -> Void,
                onJoinDiscord: @escaping () -> Void,
                onOpenWebsite: @escaping () -> Void,
                onSetShowAtStartup: @escaping (Bool) -> Void,
                onClose: @escaping () -> Void) {
        self.versionText = versionText
        self.taglines = taglines
        self.recents = recents
        self.showAtStartup = showAtStartup
        self.githubIcon = githubIcon
        self.discordIcon = discordIcon
        self.onOpenRecent = onOpenRecent
        self.onNewProject = onNewProject
        self.onOpenProject = onOpenProject
        self.onClearRecents = onClearRecents
        self.onStarGitHub = onStarGitHub
        self.onJoinDiscord = onJoinDiscord
        self.onOpenWebsite = onOpenWebsite
        self.onSetShowAtStartup = onSetShowAtStartup
        self.onClose = onClose
    }

    /// Live pointer position over the LEFT panel, in its local space (= the grid Canvas's space, both
    /// fill the panel at zoom 1 / offset 0), driving the cursor-trail glyphs.
    @State private var cursor: CGPoint?

    public var body: some View {
        HStack(spacing: 0) {
            leftPanel
            rightPanel
        }
        .ignoresSafeArea()
        // Esc returns to the workspace (the host opens the last/sample project on the way out).
        .onExitCommand { onClose() }
    }

    // MARK: - Left panel (grid + branding, vertically centered)

    private var leftPanel: some View {
        ZStack {
            SZDotGridView.canvasBackground
            SZDotGridView(zoom: 1, offset: .zero)
            SZGridCursorTrailView(cursor: cursor, zoom: 1, offset: .zero,
                                  glyphOpacity: SZWelcomeStyle.trailGlyphOpacity)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 30) {
                brand
                community
            }
            .frame(width: 340, alignment: .leading)
            .padding(.leading, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): cursor = point
            case .ended: cursor = nil
            }
        }
    }

    private var brand: some View {
        // Even, deliberate vertical rhythm: a wider gap under the icon, then equal breathing between
        // title → version → tagline (spacing 0 + explicit paddings so the pill's height can't skew it).
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                // The macOS app-icon image bakes in ~10% transparent margin, so the visible squircle
                // sits inset from the frame's left edge. Nudge left so it lines up with the text block.
                .offset(x: -8)
                .padding(.bottom, 14)
            Text("SubjectiveZero").font(.system(size: 29, weight: .semibold)).foregroundStyle(SZWelcomeStyle.text)
            // "Version" stays plain (flush-left with the title/tagline); only the numbers live in the
            // copy pill.
            HStack(spacing: 7) {
                Text("Version").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                SZVersionPill(display: versionText, copyText: "Version \(versionText)")
            }
            .padding(.top, 9)
            if !taglines.isEmpty {
                SZCyclingTagline(taglines: taglines).padding(.top, 9)
            }
        }
    }

    private var community: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                SZWelcomeButton(title: "Star on GitHub", icon: githubIcon, primary: true, action: onStarGitHub)
                SZWelcomeButton(title: "Join the Discord", icon: discordIcon, action: onJoinDiscord)
                SZWelcomeButton(title: "Official Website", icon: Image(systemName: "globe"), action: onOpenWebsite)
            }

            Toggle(isOn: Binding(get: { showAtStartup }, set: { onSetShowAtStartup($0) })) {
                Text("Show this window at startup").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .tint(SZWelcomeStyle.accent)
        }
    }

    // MARK: - Right panel (plain dark, recents + actions)

    private var rightPanel: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.092), Color(white: 0.055)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECENT PROJECTS")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color.white.opacity(0.42))
                    Spacer()
                    if !recents.isEmpty {
                        SZWelcomePill(title: "Clear", action: onClearRecents)
                    }
                }
                .frame(height: 20)

                // Recents and the New/Open row sit as one tight block (recents are content-sized — the
                // host caps the count — so the buttons hug them instead of drifting to the panel bottom).
                VStack(alignment: .leading, spacing: 8) {
                    if recents.isEmpty {
                        emptyState
                    } else {
                        ForEach(recents) { recent in
                            SZWelcomeRecentRow(recent: recent) { onOpenRecent(recent.id) }
                        }
                    }
                    HStack(spacing: 9) {
                        SZWelcomeButton(title: "New Project", icon: Image(systemName: "plus"),
                                        primary: true, attention: true, action: onNewProject)
                        SZWelcomeButton(title: "Open…", icon: Image(systemName: "folder"),
                                        action: onOpenProject)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(width: 340, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Rectangle().fill(SZWelcomeStyle.hairSoft).frame(width: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No projects yet").font(.system(size: 14, weight: .medium)).foregroundStyle(SZWelcomeStyle.text)
            Text("Create one to get started, or open an existing .subz.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(SZWelcomeStyle.hair))
    }
}

// MARK: - Building blocks

/// The tagline area, gently cycling a short list of one-liners with a fade + slide (a plain crossfade
/// under Reduce Motion). Fixed height so a 1- vs 2-line line never nudges the layout.
private struct SZCyclingTagline: View {
    let taglines: [String]
    @State private var idx = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(taglines[min(idx, taglines.count - 1)])
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id(idx)
                .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: .offset(y: 9).combined(with: .opacity),
                                  removal: .offset(y: -9).combined(with: .opacity)))
        }
        .frame(width: 340, height: 42, alignment: .topLeading)
        .task(id: taglines.count) {
            guard taglines.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4.2))
                withAnimation(.easeInOut(duration: 0.5)) { idx = (idx + 1) % taglines.count }
            }
        }
    }
}

/// The launcher's pill button. `primary` = solid ember fill + ember border (Star on GitHub, New
/// Project); otherwise a dark bordered pill. All share the same white label/icon. Full-width in its
/// row; hover BRIGHTENS both variants.
private struct SZWelcomeButton: View {
    let title: String
    let icon: Image
    var primary: Bool = false
    /// A small, slow pulse of the button's fill colour, drawing the eye to the main action (New
    /// Project) with no glow or motion across its face. Subtle; disabled under Reduce Motion.
    var attention: Bool = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(title).font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            }
            .font(.system(size: 13, weight: .semibold))   // sizes the SF Symbol icon (Text sets its own)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(background)
                    // The attention pulse: an ember tint that breathes behind the label. Driven by a
                    // TimelineView — the overlay is present whenever `attention` (never inserted/removed
                    // at runtime, so it can't animate itself into place), it just PAUSES and fades to
                    // nothing under the cursor. (A conditional `if !hover` overlay used to "fly in".)
                    .overlay {
                        if attention && !reduceMotion {
                            TimelineView(.animation(paused: hover)) { timeline in
                                let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 3.9) + 1) / 2
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(SZWelcomeStyle.accent)
                                    .opacity(hover ? 0 : 0.08 + 0.26 * phase)
                            }
                            .allowsHitTesting(false)
                        }
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(primary ? SZWelcomeStyle.accent.opacity(hover ? 0.75 : 0.5)
                                    : Color.white.opacity(hover ? 0.18 : 0.10),
                            lineWidth: 1)
            }
            .foregroundStyle(SZWelcomeStyle.text)   // white label + icon on every button
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var background: Color {
        guard primary else { return hover ? SZWelcomeStyle.btnHover : SZWelcomeStyle.btnFill }
        return hover ? SZWelcomeStyle.primaryFillHover : SZWelcomeStyle.primaryFill
    }
}

/// The version shown as a copy pill — click copies the full "Version x (build)" string, the trailing
/// glyph morphing doc→check with a symbol bounce so the copy registers.
private struct SZVersionPill: View {
    let display: String
    let copyText: String
    @State private var copied = false
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(copyText, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.3)); copied = false }
        } label: {
            HStack(spacing: 6) {
                Text(display).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied ? SZWelcomeStyle.accent : Color.white.opacity(hover ? 0.7 : 0.4))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.bounce, value: reduceMotion ? false : copied)
            }
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: hover ? 0.19 : 0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(hover ? 0.16 : 0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(copied ? "Copied" : "Copy version")
        .accessibilityLabel("Copy version")
        .accessibilityValue(copied ? "Copied" : "")
    }
}

/// The small "Clear" pill by RECENT PROJECTS — muted until hover, then brightens toward the accent.
private struct SZWelcomePill: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                .padding(.vertical, 3).padding(.horizontal, 10)
                .foregroundStyle(hover ? SZWelcomeStyle.accentSoft : Color.white.opacity(0.42))
                .background(Capsule().fill(hover ? Color.white.opacity(0.07) : Color.clear))
                .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.18 : 0.10), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A recent-project row with a hover fill — mirrors the node card's fill/hover tokens.
private struct SZWelcomeRecentRow: View {
    let recent: SZWelcomeRecent
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.name).font(SZNodeCardStyle.titleFont)
                    Text(recent.path)
                        .font(SZNodeCardStyle.valueFont).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hover ? SZNodeCardStyle.cardHoverFill : SZNodeCardStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SZNodeCardStyle.cardStroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

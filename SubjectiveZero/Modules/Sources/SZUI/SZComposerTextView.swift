// SPDX-License-Identifier: AGPL-3.0-only
// The chat composer's text input, backed by NSTextView instead of SwiftUI's TextField.
//
// Why AppKit: a plain SwiftUI TextField greedily turns a dropped file or a pasted file into *text* (its
// absolute path / filename), so file attachments never reach our handler. An NSTextView lets us override
// `paste(_:)` and the drag operations to route file URLs / images to `onAttach` and fall back to normal
// text behavior otherwise. Plain typing, Return-to-send (⇧Return = newline), a placeholder, and growth
// from one line up to `maxLines` are preserved so it reads like the TextField it replaces.
//
// Mentions: the buffer carries @mention TOKENS — runs of display text ("@Blur") tagged with a custom
// `.szMention` attribute (accent-colored, same font metrics so the height math never changes). The
// SwiftUI-facing value is `SZComposerDraft` (segments), rebuilt from attribute runs on every edit.
// Tokens are atomic: the caret can't land inside one, a partial deletion removes the whole token, and
// any run whose text no longer matches its token (exotic input paths) degrades cleanly to plain text.
// Typing/paste stays plain (`isRichText = false`); tokens only enter programmatically (autocomplete
// pick / host draft injection).
import AppKit
import SwiftUI
import SZCore

struct SZComposerTextView: NSViewRepresentable {
    @Binding var draft: SZComposerDraft
    @Binding var height: CGFloat            // driven up from the content so the field grows 1…maxLines
    var placeholder: String
    var maxLines: Int = 6
    var onSubmit: () -> Void
    var onAttach: ([URL]) -> Void           // file URLs from drag / paste (pasted images → temp PNGs)
    /// The live `@query` at the caret (nil = no session) — drives the panel's autocomplete list.
    var onMentionSession: (String?) -> Void = { _ in }
    /// Keyboard routed to the autocomplete while a session is active (↑/↓/Return/Tab/Esc). Returns
    /// whether the panel consumed it — an unconsumed Return falls through to send.
    var onMentionCommand: (SZMentionCommand) -> Bool = { _ in false }
    /// The panel's imperative channel back into the buffer (a clicked/committed candidate).
    var relay: SZComposerCommandRelay? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SZPasteDropTextView(frame: .zero)
        tv.registerForDraggedTypes([.fileURL, .png, .tiff, .string])   // .string keeps normal text drag working
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Coordinator.bodyFont
        tv.textColor = .labelColor
        tv.typingAttributes = Coordinator.bodyAttributes
        tv.textContainerInset = NSSize(width: 0, height: 3)
        // Standard "wrap to the scroll view's width, grow vertically" config — without it the container
        // width stays 0 and a long typed line won't wrap or grow the field (only explicit ⇧Return would).
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholder = placeholder
        tv.onAttach = onAttach
        context.coordinator.textView = tv
        context.coordinator.apply(draft, to: tv)
        relay?.insertMention = { [weak coordinator = context.coordinator] in coordinator?.insertMention($0) }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = tv
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)   // focus on appear, like the old composer
            context.coordinator.recalcHeight()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self   // refresh captured closures (onSubmit) for this update
        guard let tv = scroll.documentView as? SZPasteDropTextView else { return }
        // Echo guard: only push the binding INTO the view when it didn't come FROM the view (an
        // injected suggestion / a send clearing it) — else every keystroke would round-trip through
        // SwiftUI and teleport the caret to the end.
        if draft != context.coordinator.lastEmittedDraft {
            context.coordinator.apply(draft, to: tv)
        }
        tv.placeholder = placeholder
        tv.onAttach = onAttach
        relay?.insertMention = { [weak coordinator = context.coordinator] in coordinator?.insertMention($0) }
        DispatchQueue.main.async { context.coordinator.recalcHeight() }   // defer: don't mutate height mid-update
    }

    /// The value carried by a `.szMention` attribute run: the addressed entity + the exact rendered
    /// text ("@Blur"). A class on purpose — attribute equality is identity, so two adjacent tokens
    /// never merge into one run, and normalization can compare a run's live text against `text`.
    final class SZMentionRunValue: NSObject {
        let target: SZMentionTarget
        let text: String
        init(target: SZMentionTarget, text: String) {
            self.target = target
            self.text = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SZComposerTextView
        weak var textView: SZPasteDropTextView?
        /// The last draft this coordinator emitted (or applied) — the updateNSView echo guard.
        var lastEmittedDraft: SZComposerDraft?
        /// True while the coordinator performs its own expanded replacement, so the delegate's
        /// token guard doesn't recurse into it.
        private var performingTokenEdit = false

        init(_ parent: SZComposerTextView) { self.parent = parent }

        static let mentionKey = NSAttributedString.Key("sz.mention")
        static let bodyFont = NSFont.systemFont(ofSize: 12.5)
        // Same font SIZE as body text (a token wraps and measures like any word — the line-height
        // math in recalcHeight stays valid); weight + accent color make it read as a chip.
        static let mentionFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        static let mentionColor = NSColor(srgbRed: 0.50, green: 0.64, blue: 1.0, alpha: 1.0)
        static let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
        ]

        // MARK: - Draft ↔ storage

        /// Push a draft into the view (initial content, injection, post-send clear). Programmatic —
        /// not undoable, caret lands at the end.
        func apply(_ draft: SZComposerDraft, to tv: NSTextView) {
            lastEmittedDraft = draft
            tv.textStorage?.setAttributedString(Self.attributedString(from: draft))
            tv.setSelectedRange(NSRange(location: tv.textStorage?.length ?? 0, length: 0))
            tv.typingAttributes = Self.bodyAttributes
            tv.needsDisplay = true   // placeholder redraw when cleared
        }

        static func attributedString(from draft: SZComposerDraft) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for segment in draft.segments {
                switch segment {
                case .text(let text):
                    out.append(NSAttributedString(string: text, attributes: bodyAttributes))
                case .mention(let target, let display):
                    out.append(mentionToken(target: target, display: display))
                }
            }
            return out
        }

        static func mentionToken(target: SZMentionTarget, display: String) -> NSAttributedString {
            let text = "@\(display)"
            return NSAttributedString(string: text, attributes: [
                .font: mentionFont, .foregroundColor: mentionColor,
                mentionKey: SZMentionRunValue(target: target, text: text),
            ])
        }

        /// Rebuild the draft from the storage's attribute runs (adjacent text runs merged).
        static func draft(from storage: NSTextStorage) -> SZComposerDraft {
            var segments: [SZMessageSegment] = []
            let string = storage.string as NSString
            storage.enumerateAttribute(mentionKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let text = string.substring(with: range)
                if let run = value as? SZMentionRunValue {
                    segments.append(.mention(run.target, display: String(run.text.dropFirst())))
                } else if case .text(let previous) = segments.last {
                    segments[segments.count - 1] = .text(previous + text)
                } else {
                    segments.append(.text(text))
                }
            }
            return SZComposerDraft(segments: segments)
        }

        // MARK: - Token invariants

        /// The token run covering character `index`, if any.
        private func tokenRange(at index: Int, in storage: NSTextStorage) -> NSRange? {
            guard index >= 0, index < storage.length else { return nil }
            var range = NSRange()
            let full = NSRange(location: 0, length: storage.length)
            guard storage.attribute(Self.mentionKey, at: index, longestEffectiveRange: &range, in: full) != nil
            else { return nil }
            return range
        }

        /// A boundary at `index` is STRICTLY inside a token when the token covers the characters on
        /// both sides of it.
        private func tokenSurrounding(boundary index: Int, in storage: NSTextStorage) -> NSRange? {
            guard let token = tokenRange(at: index, in: storage), index > token.location else { return nil }
            return token
        }

        /// Belt-and-braces degrade: any token whose live text no longer matches its value (dictation,
        /// autocorrect substitution, exotic input paths the delegate guards missed) becomes plain text.
        private func normalizeTokens(in storage: NSTextStorage) {
            var stale: [NSRange] = []
            let string = storage.string as NSString
            storage.enumerateAttribute(Self.mentionKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let run = value as? SZMentionRunValue else { return }
                if string.substring(with: range) != run.text { stale.append(range) }
            }
            for range in stale { storage.setAttributes(Self.bodyAttributes, range: range) }
        }

        // The caret never lands INSIDE a token; a selection endpoint inside one extends to cover it.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return new }
            var range = new
            if range.length == 0 {
                if let token = tokenSurrounding(boundary: range.location, in: storage) {
                    // Snap in the direction of travel (arrow left → token start, right → its end).
                    let movingLeft = new.location < old.location
                    range.location = movingLeft ? token.location : token.location + token.length
                }
            } else {
                if let token = tokenSurrounding(boundary: range.location, in: storage) {
                    let end = range.location + range.length
                    range.location = token.location
                    range.length = end - range.location
                }
                if let token = tokenSurrounding(boundary: range.location + range.length, in: storage) {
                    range.length = token.location + token.length - range.location
                }
            }
            return range
        }

        // Typing after/adjacent to a token must not inherit its attributes. Caret moves also
        // start/cancel the mention session (clicking away from the `@query` ends it).
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tv.typingAttributes = Self.bodyAttributes
            updateMentionSession(tv)
        }

        // MARK: - Mention autocomplete session

        /// The buffer range of the active `@query` (including the `@`), nil when no session.
        private var mentionSessionRange: NSRange?
        private var lastEmittedQuery: String??

        private func updateMentionSession(_ tv: NSTextView) {
            let session = detectMentionSession(tv)
            mentionSessionRange = session?.range
            if session?.query != lastEmittedQuery.flatMap({ $0 }) || lastEmittedQuery == nil {
                lastEmittedQuery = .some(session?.query)
                parent.onMentionSession(session?.query)
            }
        }

        /// Scan back from the caret for an `@` that opens a session: at a word boundary, on the
        /// caret's line, with no token between it and the caret, and not immediately followed by
        /// whitespace. UTF-16 unit-wise scan is safe — every delimiter checked is a single unit.
        private func detectMentionSession(_ tv: NSTextView) -> (range: NSRange, query: String)? {
            guard !tv.hasMarkedText(), let storage = tv.textStorage else { return nil }
            let selection = tv.selectedRange()
            guard selection.length == 0, selection.location <= storage.length else { return nil }
            let text = storage.string as NSString
            let at: unichar = 0x40, newline: unichar = 0x0A
            let floor = max(0, selection.location - 64)   // bound the scan; queries are short
            var i = selection.location - 1
            while i >= floor {
                let unit = text.character(at: i)
                if unit == newline { return nil }
                if unit == at {
                    // Word boundary: line start or whitespace before the `@`.
                    if i > 0 {
                        let before = text.character(at: i - 1)
                        let scalar = UnicodeScalar(before)
                        if !(scalar.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false) { return nil }
                    }
                    let range = NSRange(location: i, length: selection.location - i)
                    // No token inside the candidate range (an inserted mention ends the session).
                    var hasToken = false
                    storage.enumerateAttribute(Self.mentionKey, in: range) { value, _, stop in
                        if value != nil { hasToken = true; stop.pointee = true }
                    }
                    if hasToken { return nil }
                    let query = text.substring(with: NSRange(location: i + 1, length: range.length - 1))
                    if let first = query.first, first.isWhitespace { return nil }
                    return (range, query)
                }
                i -= 1
            }
            return nil
        }

        /// Replace the active `@query` (or the caret selection) with an atomic mention token + a
        /// trailing plain space (terminates the session, gives the caret a plain landing spot).
        /// Undo-coherent: goes through shouldChangeText/didChangeText.
        func insertMention(_ candidate: SZMentionCandidate) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = mentionSessionRange ?? tv.selectedRange()
            let insertion = NSMutableAttributedString()
            insertion.append(Self.mentionToken(target: candidate.target, display: candidate.title))
            insertion.append(NSAttributedString(string: " ", attributes: Self.bodyAttributes))
            performingTokenEdit = true
            defer { performingTokenEdit = false }
            if tv.shouldChangeText(in: range, replacementString: insertion.string) {
                storage.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
                tv.typingAttributes = Self.bodyAttributes
            }
        }

        // A deletion/replacement that PARTIALLY covers a token expands to the whole token (backspace
        // on a token's tail removes the token). Performed here so undo restores the attributed run.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard !performingTokenEdit, affectedRange.length > 0,
                  let storage = textView.textStorage, !textView.hasMarkedText() else { return true }
            var expanded = affectedRange
            if let token = tokenSurrounding(boundary: expanded.location, in: storage) {
                let end = expanded.location + expanded.length
                expanded.location = token.location
                expanded.length = end - expanded.location
            }
            if let token = tokenSurrounding(boundary: expanded.location + expanded.length, in: storage) {
                expanded.length = token.location + token.length - expanded.location
            }
            guard expanded != affectedRange else { return true }
            performingTokenEdit = true
            defer { performingTokenEdit = false }
            let replacement = replacementString ?? ""
            if textView.shouldChangeText(in: expanded, replacementString: replacement) {
                storage.replaceCharacters(
                    in: expanded,
                    with: NSAttributedString(string: replacement, attributes: Self.bodyAttributes))
                textView.didChangeText()
                textView.setSelectedRange(
                    NSRange(location: expanded.location + (replacement as NSString).length, length: 0))
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            if !tv.hasMarkedText() { normalizeTokens(in: storage) }
            let draft = Self.draft(from: storage)
            lastEmittedDraft = draft
            parent.draft = draft
            recalcHeight()
            updateMentionSession(tv)
        }

        // Mention-session keys route to the autocomplete FIRST (an unconsumed Return falls through
        // to send — e.g. the filter matched nothing). Then: Return sends; ⇧Return inserts a newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if mentionSessionRange != nil, let command = Self.mentionCommand(for: selector),
               parent.onMentionCommand(command) {
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        private static func mentionCommand(for selector: Selector) -> SZMentionCommand? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): .commit
            case #selector(NSResponder.cancelOperation(_:)): .dismiss
            default: nil
            }
        }

        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let inset = tv.textContainerInset.height * 2
            let line = ("Mg" as NSString).size(withAttributes: [.font: tv.font as Any]).height
            let used = lm.usedRect(for: tc).height
            let clamped = min(max(used, line), line * CGFloat(parent.maxLines))
            let h = (clamped + inset).rounded()
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }
    }
}

/// The NSTextView subclass that turns dropped/pasted files + images into attachments.
final class SZPasteDropTextView: NSTextView {
    var onAttach: (([URL]) -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    // ⌘V: route files / images to attachments; otherwise normal text paste.
    override func paste(_ sender: Any?) {
        if handleAttachmentPasteboard(NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasAttachments(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handleAttachmentPasteboard(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func pasteboardHasAttachments(_ pb: NSPasteboard) -> Bool {
        pb.hasFileURLs || pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }
    private func handleAttachmentPasteboard(_ pb: NSPasteboard) -> Bool {
        let urls = pb.fileURLs
        if !urls.isEmpty { onAttach?(urls); return true }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            let temp = images.compactMap(Self.writeTempImage)
            if !temp.isEmpty { onAttach?(temp); return true }
        }
        return false
    }

    /// Write a pasted/dropped file-less image to a temp PNG so it can be staged like any other attachment.
    static func writeTempImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pasted-\(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
}

/// A whole-area file-drop target, used as a `.background` so a file dropped ANYWHERE on the chat panel
/// attaches (SwiftUI's `.dropDestination` on a parent only catches where child views pass the drag
/// through — the transcript — so the tab strip / composer chrome were dead zones). Sitting behind the
/// content, it receives drags the SwiftUI views don't consume while leaving normal clicks to them.
struct SZFileDropCatcher: NSViewRepresentable {
    /// `onDrop(urls, point)` — `point` is the drop location in the view's own top-left space (AppKit's
    /// bottom-left `draggingLocation` is flipped for it), which matches a SwiftUI coordinate space that
    /// shares this view's frame. Callers that don't care about placement (the chat panel) ignore it.
    var onDrop: ([URL], CGPoint) -> Bool
    var onTargeted: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = DropView()
        v.onDrop = onDrop
        v.onTargeted = onTargeted
        v.registerForDraggedTypes([.fileURL])
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? DropView else { return }
        v.onDrop = onDrop
        v.onTargeted = onTargeted
    }

    final class DropView: NSView {
        var onDrop: (([URL], CGPoint) -> Bool)?
        var onTargeted: ((Bool) -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingPasteboard.hasFileURLs else { return [] }
            onTargeted?(true)
            return .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted?(false)
            let urls = sender.draggingPasteboard.fileURLs
            guard !urls.isEmpty else { return false }
            // AppKit's draggingLocation is window-space, bottom-left origin; convert to this view then
            // flip Y so the point is top-left (what SwiftUI coordinate spaces use).
            let inView = convert(sender.draggingLocation, from: nil)
            let point = CGPoint(x: inView.x, y: bounds.height - inView.y)
            return onDrop?(urls, point) ?? false
        }
    }
}

private extension NSPasteboard {
    /// File URLs on the pasteboard (drag or clipboard), empty if none.
    var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    var hasFileURLs: Bool {
        canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

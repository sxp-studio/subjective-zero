// SPDX-License-Identifier: AGPL-3.0-only
// Inline control for an unconnected input: the right widget for the port type, two-way bound
// to the port's default. `onSet(value, persist)` routes to the host (ui_set_input_default → store +
// runtime live + disk) — `persist:false` for a live preview (slider drag / string keystroke), `true` to
// commit. bool→toggle, float-with-range→slider, enum→dropdown (over `options`), string→text field (or an
// open-panel button when it marks itself a path with `ui.kind == .filePicker`) are functional, and
// float/float2/3/4 get one numeric field per component (commit on Enter/blur); colors
// + matrices still render read-only. Texture/event ports + connected inputs have no control.
// `onSet == nil` → read-only.
import AppKit
import SwiftUI
import SZCore

struct SZPortControl: View {
    let port: SZPort
    var locked: Bool = false
    /// The port is declared but the running build was never compiled against it, so nothing reads it yet
    /// and the control is read-only until the node is rebuilt. Card width is unaffected:
    /// `SZNodeLayout.controlWidth` reserves by port type and never asks what the build knows, so the
    /// read-only form sits inside the same column and no socket moves when a port is declared.
    var notInBuild: Bool = false
    /// Set when the host's audit says this port's file can't be read (`SZNode.unreadableInputs`): the
    /// file chip turns red and carries the reason as its tooltip. nil for every healthy port.
    var fault: String? = nil
    /// The card-wide numeric-cell width (SZNodeLayout.numericFieldWidth(of:)) — injected by SZNodeView
    /// so cells line up in one column grid across rows of different arity.
    let fieldWidth: CGFloat
    /// Effective enum choices: the static `port.options` today, the node's dynamic list once Step 3 wires
    /// it through. Empty → an enum renders as a read-only chip.
    var options: [SZEnumOption] = []
    /// Re-resolves the effective choices when the dropdown opens (Menu content is built lazily). The node
    /// cards skip re-rendering while nothing they show changes, so a dynamic enum (e.g. the camera list)
    /// can't rely on body re-evaluation for freshness — pulling here keeps "open the menu, see the
    /// just-connected device" working. `nil` → the menu lists the snapshot in `options`.
    var freshOptions: (() -> [SZEnumOption])? = nil
    var onSet: ((SZPortValue, _ persist: Bool) -> Void)? = nil
    /// Reports whether a field of this control holds the keyboard. The canvas selects a card on every
    /// tap and claims keyboard focus with it, which would take the keyboard straight back off the
    /// field the same click just landed in — the panel skips that claim while this says true.
    var onFieldEditingChanged: ((Bool) -> Void)? = nil

    private var editable: Bool { Self.isEditable(hasSetter: onSet != nil, locked: locked, notInBuild: notInBuild) }

    /// The one rule for whether this control accepts input: it needs a setter, an unheld card, and a port
    /// the running build actually reads. A port declared ahead of the code is read-only rather than a knob
    /// that changes nothing.
    static func isEditable(hasSetter: Bool, locked: Bool, notInBuild: Bool) -> Bool {
        hasSetter && !locked && !notInBuild
    }

    /// Debounced ColorPicker disk commit — see `colorWell`.
    @State private var pendingColorCommit: Task<Void, Never>? = nil

    /// The value the slider drag last produced, nil when no drag is in flight — what the release
    /// commits. It cannot re-read `port.def`: SwiftUI hands `onEditingChanged` the `self` captured
    /// when tracking began, so the value read back through it is the one from before the drag, and
    /// committing that wrote the whole drag away (measured: the live ticks land, then the release
    /// puts the pre-drag value back 70ms later). `@State` is read through its storage rather than
    /// through the captured struct, so it answers live no matter which snapshot the callback holds.
    @State private var sliderDrag: Double? = nil

    /// Which cell of this control holds the keyboard, so its well can say so. A control is a row of
    /// numeric cells or one string field, never both, so one index answers for either (the string
    /// field is 0).
    @FocusState private var focusedCell: Int?

    var body: some View {
        control
            .onChange(of: focusedCell) { _, cell in onFieldEditingChanged?(cell != nil) }
            // A control that leaves the tree while it holds the keyboard (the card folds its plugs,
            // the zoom crosses the tile threshold, a wire lands on this port) never gets to report
            // the blur any other way. Reporting false for a field that wasn't focused is a no-op.
            .onDisappear { onFieldEditingChanged?(false) }
            // A lock swaps the field for a read-only chip in place, which is not a disappearance
            // and may leave the focus binding set; dropping it here reports the loss through the
            // reporter above.
            .onChange(of: editable) { _, ok in if !ok { focusedCell = nil } }
    }

    @ViewBuilder
    private var control: some View {
        switch port.type {
        case .bool:
            Toggle("", isOn: Binding(get: { boolValue }, set: { onSet?(.bool($0), true) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!editable)
        case .float where sliderRange != nil:
            HStack(spacing: SZNodeLayout.sliderValueSpacing) {
                // Continuous track, quantized in the setter — a stepped macOS Slider grows tick marks
                // (dense dot row) and shifts its track above the row's vertical center.
                Slider(value: Binding(get: { sliderDrag ?? floatValue },
                                      set: { value in
                                          let stepped = SZPort.stepped(value, in: sliderRange!, step: port.ui?.step)
                                          sliderDrag = stepped
                                          onSet?(.float(stepped), false)
                                      }),
                       in: sliderRange!,
                       // Commit what the drag produced, never what this view last read — see `sliderDrag`.
                       // No drag ticks means nothing was previewed, so there is nothing to commit.
                       onEditingChanged: { editing in
                           // Every tracking session starts clean, whatever ended the last one.
                           if editing { sliderDrag = nil; return }
                           guard let dragged = sliderDrag else { return }
                           sliderDrag = nil
                           onSet?(.float(dragged), true)
                       })
                    .controlSize(.mini).frame(width: SZNodeLayout.sliderTrackWidth)
                    .disabled(!editable)
                    // Disabling ends AppKit's tracking without the release callback: drop the
                    // in-flight drag or the knob stays pinned to it while the number moves on.
                    .onChange(of: editable) { _, ok in if !ok { sliderDrag = nil } }
                Text(String(format: "%.2f", floatValue))
                    .font(SZNodeCardStyle.valueFont).foregroundStyle(SZNodeCardStyle.valueColor)
                    // Fixed value column (tracks align across rows), sized to the widest value the
                    // range can produce so "10.00" / "-0.50" never truncate.
                    .frame(width: SZNodeLayout.sliderValueColumnWidth(sliderRange!), alignment: .trailing)
            }
        case .enumeration:
            if editable, !options.isEmpty {
                enumMenu
            } else {
                chip(currentLabel.isEmpty ? "—" : currentLabel, chevron: true)
            }
        case .string where port.ui?.kind == .filePicker:
            // A path port marks itself with `ui.kind == .filePicker` (there is no `file` type). Render an
            // open-panel button, not a text field, so the user picks a file instead of typing a raw path.
            if editable {
                Button(action: chooseFile) { filePickerLabel }
                    .buttonStyle(.plain).fixedSize()
            } else {
                chip(stringValue.isEmpty ? "—" : lastPathComponent(stringValue), chevron: false)
            }
        case .string:
            if editable {
                TextField("", text: Binding(get: { stringValue }, set: { onSet?(.string($0), false) }))
                    .textFieldStyle(.plain).font(SZNodeCardStyle.valueFont)
                    .multilineTextAlignment(.trailing).frame(width: SZNodeLayout.stringFieldWidth)
                    .onSubmit { onSet?(.string(stringValue), true) }
                    .focused($focusedCell, equals: 0)
                    .padding(.horizontal, SZNodeLayout.fieldHorizontalPadding).padding(.vertical, 2)
                    .background(fieldWell(focused: focusedCell == 0))
            } else {
                chip(stringValue.isEmpty ? "—" : stringValue, chevron: false)
            }
        case .float, .float2, .float3, .float4:
            if editable {
                floatFields
            } else {
                readOnlyWells((0..<componentCount).map(component))
            }
        case .colorRGB, .colorRGBA:
            if editable {
                colorWell
            } else {
                readOnlySwatch
            }
        case .float3x3, .float4x4:
            // Zero-padded like the editable path — a matrix without a default still shows 4 cells.
            readOnlyWells((0..<4).map(component))
        case .texture, .event, .floatArray:
            EmptyView()
        }
    }

    /// One numeric text field per component (float → 1 … float4 → 4), committing on Enter/focus loss
    /// (a value-bound TextField has no meaningful keystroke preview, so every commit persists). All
    /// cells share the injected card-wide width, so the card resizes with the values.
    private var floatFields: some View {
        let count = componentCount
        return HStack(spacing: SZNodeLayout.cellSpacing) {
            ForEach(0..<count, id: \.self) { i in
                numericCell(TextField("", value: Binding(get: { component(i) },
                                                         set: { setComponent(i, to: $0, count: count) }),
                                      format: .number.precision(.fractionLength(0...3)).grouping(.never))
                    .textFieldStyle(.plain)
                    .focused($focusedCell, equals: i))
                    .background(fieldWell(focused: focusedCell == i))
            }
        }
    }

    /// Read-only numerics render per-component cells on the same scaffold as the editable fields
    /// (parseable, column-aligned) but in the card's read-only language: borderless capsules with dim
    /// text — the crisp bordered square well stays exclusive to "you can type here". Matrices show
    /// their first 4 components (no trailing ellipsis — it pushed these rows off the shared right
    /// margin for near-zero information; the port label already says it's a matrix).
    private func readOnlyWells(_ values: [Double]) -> some View {
        HStack(spacing: SZNodeLayout.cellSpacing) {
            ForEach(values.indices, id: \.self) { i in
                numericCell(Text(values[i].formatted(.number.precision(.fractionLength(0...3)).grouping(.never)))
                    .foregroundStyle(SZNodeCardStyle.readOnlyValueColor))
                    .background(Capsule().fill(SZNodeCardStyle.chipFill))
            }
        }
    }

    /// The one numeric-cell scaffold — editable fields and read-only cells share this exact geometry
    /// (card-wide width, trailing alignment, cell padding), so the column grid cannot drift.
    private func numericCell(_ content: some View) -> some View {
        content
            .font(SZNodeCardStyle.valueFont)
            .multilineTextAlignment(.trailing)
            .frame(width: fieldWidth, alignment: .trailing)
            .padding(.horizontal, SZNodeLayout.cellHorizontalPadding).padding(.vertical, 2)
    }

    /// Native color-picker swatch for colorRGB/RGBA. The system panel streams continuous updates with
    /// no editing-ended signal, so each change previews live (persist:false — store + runtime, no disk)
    /// and the disk commit fires once the panel goes quiet for 400ms. The pending Task outlives the
    /// view if the control disappears mid-debounce, so the commit still lands (a deleted node's commit
    /// no-ops in the store).
    private var colorWell: some View {
        ColorPicker("", selection: Binding(get: { colorValue }, set: { setColor($0) }),
                    supportsOpacity: port.type == .colorRGBA)
            .labelsHidden().controlSize(.mini)
    }

    private var readOnlySwatch: some View {
        RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
            .fill(colorValue)
            .overlay(RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
                .stroke(SZNodeCardStyle.fieldStroke, lineWidth: 0.75))
            .frame(width: 28, height: 14)
    }

    private var colorValue: Color {
        let c = components
        return Color(.sRGB,
                     red: c.count > 0 ? c[0] : 0,
                     green: c.count > 1 ? c[1] : 0,
                     blue: c.count > 2 ? c[2] : 0,
                     opacity: c.count > 3 ? c[3] : 1)
    }

    private func setColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        let comps = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        let value: SZPortValue = port.type == .colorRGBA
            ? .colorRGBA(comps + [Double(rgb.alphaComponent)])
            : .colorRGB(comps)
        onSet?(value, false)                                  // live preview: store + runtime, no disk
        let commit = onSet
        pendingColorCommit?.cancel()
        pendingColorCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit?(value, true)                              // panel went quiet → one disk write
        }
    }

    private var componentCount: Int { SZNodeLayout.componentCount(port.type) }

    /// The port default's flat components ([] when unset — fields then read 0).
    private var components: [Double] {
        switch port.def {
        case .float(let v): [v]
        case .float2(let a), .float3(let a), .float4(let a),
             .colorRGB(let a), .colorRGBA(let a), .float3x3(let a), .float4x4(let a): a
        default: []
        }
    }

    private func component(_ i: Int) -> Double {
        i < components.count ? components[i] : 0
    }

    /// Rebuild the typed vector with component `i` replaced and commit it (store + live render).
    private func setComponent(_ i: Int, to value: Double, count: Int) {
        var a = (0..<count).map(component)
        a[i] = value
        switch port.type {
        case .float2: onSet?(.float2(a), true)
        case .float3: onSet?(.float3(a), true)
        case .float4: onSet?(.float4(a), true)
        default: onSet?(.float(a[0]), true)
        }
    }

    private var enumMenu: some View {
        Menu {
            // Fresh resolution when the menu opens (already dynamic-??-static — see the caller);
            // an empty fresh list (device vanished mid-session) keeps the snapshot rather than
            // presenting a blank menu.
            let live = freshOptions?() ?? []
            let effective = live.isEmpty ? options : live
            ForEach(effective, id: \.value) { opt in
                Button { onSet?(.enumeration(opt.value), true) } label: {
                    if opt.value == stringValue {
                        Label(opt.label, systemImage: "checkmark")
                    } else {
                        Text(opt.label)
                    }
                }
            }
        } label: {
            chip(currentLabel.isEmpty ? "—" : currentLabel, chevron: true)
        }
        // .plain button style (not .borderlessButton menu style) — macOS's borderless pull-down
        // substitutes its own proportional label + leading indicator, dropping the chip entirely.
        .buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden).fixedSize()
    }

    /// The button label for a `filePicker` path port: a raised chip like the enum dropdown, but a folder
    /// glyph in place of the chevron (a pick-action, not a menu) and the picked file's name — or
    /// "Choose…" when unset — in place of a value.
    private var filePickerLabel: some View {
        // The filename is a meaningful identifier (unlike a slider readout), so it reads at the row-label
        // size rather than the smallest value size — see SZNodeLayout.controlWidth's matching filePicker case.
        HStack(spacing: 3) {
            Image(systemName: fault == nil ? "folder" : "exclamationmark.triangle.fill")
                .font(SZNodeCardStyle.valueFont)
            Text(stringValue.isEmpty ? "Choose…" : lastPathComponent(stringValue)).lineLimit(1)
        }
        .font(SZNodeCardStyle.labelFont)
        .foregroundStyle(fault == nil ? SZNodeCardStyle.valueColor : Color.red)
        .padding(.horizontal, SZNodeLayout.chipHorizontalPadding).padding(.vertical, 2)
        .background(Capsule().fill(SZNodeCardStyle.chipFill))
        .help(fault ?? "")
    }

    /// Present a file open panel and commit the chosen path. A pick has no meaningful live-preview state
    /// (unlike a slider drag), so it commits once with `persist: true`.
    ///
    /// The port says what it accepts through `ui.fileTypes`, and the filter matches on the filename
    /// extension rather than on `allowedContentTypes`. That is deliberate:
    /// `UTType(filenameExtension: "mlpackage")` is nil on a Mac where nothing registered that type, so a
    /// content-type filter silently drops exactly the types worth declaring. Matching the extension needs
    /// no type to exist anywhere, and nothing here knows what any particular extension means.
    ///
    /// Declaring types also allows directories: several formats are packages (a folder the Finder shows
    /// as one file), and whether this Mac knows that depends on what is installed. `treatsFilePackages‑
    /// AsDirectories = false` keeps a registered package selectable as a file either way.
    private func chooseFile() {
        let types = port.ui?.acceptedExtensions ?? []
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = !types.isEmpty
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let filter = SZFileTypeFilter(extensions: types)
        panel.delegate = filter   // NSOpenPanel holds its delegate weakly…
        defer { withExtendedLifetime(filter) {} }   // …and runModal is synchronous, so pin it across the modal
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onSet?(.string(url.path), true)
    }

    private func lastPathComponent(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// The inset-well background shared by the keyboard-editable text/number fields — visually distinct
    /// from the raised `chip` capsules so "type here" and "pick from a list" read differently.
    private func fieldWell(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
            .fill(SZNodeCardStyle.fieldFill)
            .overlay(RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
                .stroke(focused ? Color.accentColor : SZNodeCardStyle.fieldStroke,
                        lineWidth: focused ? SZNodeCardStyle.focusedFieldStrokeWidth : 0.75))
    }

    private func chip(_ text: String, chevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(SZNodeCardStyle.chevronFont) }
        }
        .font(SZNodeCardStyle.valueFont)
        .foregroundStyle(SZNodeCardStyle.valueColor)
        .padding(.horizontal, SZNodeLayout.chipHorizontalPadding).padding(.vertical, 2)
        .background(Capsule().fill(SZNodeCardStyle.chipFill))
    }

    /// Whether this port renders as a slider — single-sourced with the width model and the MCP
    /// input-default path via the SZCore predicate (SZPort+Slider.swift).
    private var sliderRange: ClosedRange<Double>? { port.sliderRange }

    private var boolValue: Bool { if case .bool(let b) = port.def { return b }; return false }

    private var floatValue: Double { if case .float(let v) = port.def { return v }; return 0 }

    private var stringValue: String {
        switch port.def {
        case .enumeration(let s): s
        case .string(let s): s
        default: ""
        }
    }

    /// The label for the current enum value (falls back to the raw value if it isn't among `options`).
    private var currentLabel: String {
        options.first { $0.value == stringValue }?.label ?? stringValue
    }

}


/// Restricts an open panel to a port's declared filename extensions. Two hooks, because they cover
/// different ways of choosing: `shouldEnable` greys out non-matching files in the browser (while
/// leaving folders walkable), and `validate` catches what greying cannot — a typed path, a file
/// dragged into the panel, and "Choose" pressed on the folder currently open.
///
/// No declared extensions means no restriction, which is what every port that says nothing gets.
final class SZFileTypeFilter: NSObject, NSOpenSavePanelDelegate {
    private let extensions: [String]

    init(extensions: [String]) { self.extensions = extensions }

    private func matches(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    private func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard !extensions.isEmpty else { return true }
        // A plain folder stays enabled so the user can still navigate into it; a package or file has to
        // match. A package whose extension matches is the thing being picked.
        return matches(url) || isPlainFolder(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard !extensions.isEmpty, !matches(url) else { return }
        let kinds = extensions.map { ".\($0)" }.joined(separator: " or ")
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
            NSLocalizedDescriptionKey: "\(url.lastPathComponent) is not the kind of file this port takes.",
            NSLocalizedRecoverySuggestionErrorKey: "Choose a \(kinds) file.",
        ])
    }
}

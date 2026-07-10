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
    /// The card-wide numeric-cell width (SZNodeLayout.numericFieldWidth(of:)) — injected by SZNodeView
    /// so cells line up in one column grid across rows of different arity.
    let fieldWidth: CGFloat
    /// Effective enum choices: the static `port.options` today, the node's dynamic list once Step 3 wires
    /// it through. Empty → an enum renders as a read-only chip.
    var options: [SZEnumOption] = []
    /// Re-resolves the effective choices when the dropdown OPENS (Menu content is built lazily). The node
    /// cards skip re-rendering while nothing they show changes, so a dynamic enum (e.g. the camera list)
    /// can't rely on body re-evaluation for freshness — pulling here keeps "open the menu, see the
    /// just-connected device" working. `nil` → the menu lists the snapshot in `options`.
    var freshOptions: (() -> [SZEnumOption])? = nil
    var onSet: ((SZPortValue, _ persist: Bool) -> Void)? = nil

    private var editable: Bool { onSet != nil && !locked }

    /// Debounced ColorPicker disk commit — see `colorWell`.
    @State private var pendingColorCommit: Task<Void, Never>? = nil

    var body: some View {
        switch port.type {
        case .bool:
            Toggle("", isOn: Binding(get: { boolValue }, set: { onSet?(.bool($0), true) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!editable)
        case .float where sliderRange != nil:
            HStack(spacing: SZNodeLayout.sliderValueSpacing) {
                // Continuous track, quantized in the setter — a stepped macOS Slider grows tick marks
                // (dense dot row) and shifts its track above the row's vertical center.
                Slider(value: Binding(get: { floatValue },
                                      set: { onSet?(.float(SZPort.stepped($0, in: sliderRange!, step: port.ui?.step)), false) }),
                       in: sliderRange!,
                       onEditingChanged: { editing in if !editing { onSet?(.float(floatValue), true) } })
                    .controlSize(.mini).frame(width: SZNodeLayout.sliderTrackWidth)
                    .disabled(!editable)
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
                    .padding(.horizontal, SZNodeLayout.fieldHorizontalPadding).padding(.vertical, 2)
                    .background(fieldWell)
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
                                      format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.plain))
                    .background(fieldWell)
            }
        }
    }

    /// Read-only numerics render per-component CELLS on the same scaffold as the editable fields
    /// (parseable, column-aligned) but in the card's read-only language: borderless capsules with dim
    /// text — the crisp bordered square well stays exclusive to "you can type here". Matrices show
    /// their first 4 components (no trailing ellipsis — it pushed these rows off the shared right
    /// margin for near-zero information; the port label already says it's a matrix).
    private func readOnlyWells(_ values: [Double]) -> some View {
        HStack(spacing: SZNodeLayout.cellSpacing) {
            ForEach(values.indices, id: \.self) { i in
                numericCell(Text(values[i].formatted(.number.precision(.fractionLength(0...3))))
                    .foregroundStyle(SZNodeCardStyle.readOnlyValueColor))
                    .background(Capsule().fill(SZNodeCardStyle.chipFill))
            }
        }
    }

    /// The ONE numeric-cell scaffold — editable fields and read-only cells share this exact geometry
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
            Image(systemName: "folder").font(SZNodeCardStyle.valueFont)
            Text(stringValue.isEmpty ? "Choose…" : lastPathComponent(stringValue)).lineLimit(1)
        }
        .font(SZNodeCardStyle.labelFont)
        .foregroundStyle(SZNodeCardStyle.valueColor)
        .padding(.horizontal, SZNodeLayout.chipHorizontalPadding).padding(.vertical, 2)
        .background(Capsule().fill(SZNodeCardStyle.chipFill))
    }

    /// Present a file open panel and commit the chosen path. A pick has no meaningful live-preview state
    /// (unlike a slider drag), so it commits once with `persist: true`. Any file — the `.filePicker` kind
    /// carries no per-port content-type today.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onSet?(.string(url.path), true)
    }

    private func lastPathComponent(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// The inset-well background shared by the keyboard-editable text/number fields — visually distinct
    /// from the raised `chip` capsules so "type here" and "pick from a list" read differently.
    private var fieldWell: some View {
        RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
            .fill(SZNodeCardStyle.fieldFill)
            .overlay(RoundedRectangle(cornerRadius: SZNodeCardStyle.fieldCornerRadius)
                .stroke(SZNodeCardStyle.fieldStroke, lineWidth: 0.75))
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

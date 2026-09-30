// SPDX-License-Identifier: AGPL-3.0-only
// shared generation chips for provider defaults and individual routing slots.
import SwiftUI

struct SZGenerationControls: View {
    let selectionLabel: String
    let options: [SZRoutingEnvelopeOption]
    let effortOptions: [String]
    let selectedEffort: String?
    let supportsFastMode: Bool
    let fastModeEnabled: Bool
    var clearLabel: String? = nil
    var isInherited = false
    var allowsDefaultEffort = false
    let onSelect: (String?, String?) -> Void
    let onSetEffort: (String?) -> Void
    let onSetFastMode: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !isInherited {
                if !effortOptions.isEmpty {
                    Menu {
                        if allowsDefaultEffort {
                            Button { onSetEffort(nil) } label: {
                                if selectedEffort == nil { Label("Default", systemImage: "checkmark") }
                                else { Text("Default") }
                            }
                            Divider()
                        }
                        ForEach(effortOptions, id: \.self) { effort in
                            Button { onSetEffort(effort) } label: {
                                if selectedEffort == effort { Label(SZGenerationLabels.effort(effort), systemImage: "checkmark") }
                                else { Text(SZGenerationLabels.effort(effort)) }
                            }
                        }
                    } label: {
                        SZChipMenuFace(text: selectedEffort.map(SZGenerationLabels.effort) ?? "Effort",
                                       quiet: selectedEffort == nil, maxWidth: 90)
                    }
                    .accessibilityLabel("Reasoning effort")
                }
                if supportsFastMode {
                    fastChip
                }
            }
            Menu {
                if let clearLabel {
                    Button { onSelect(nil, nil) } label: {
                        if isInherited { Label(clearLabel, systemImage: "checkmark") }
                        else { Text(clearLabel) }
                    }
                    Divider()
                }
                ForEach(options) { option in
                    Button { onSelect(option.providerID, option.modelID) } label: {
                        if option.isSelected { Label(option.label, systemImage: "checkmark") }
                        else { Text(option.label) }
                    }
                    .disabled(!option.isEnabled)
                }
            } label: {
                SZChipMenuFace(text: selectionLabel, quiet: isInherited)
            }
            .accessibilityLabel("Model")
            .disabled(options.isEmpty && clearLabel == nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var fastChip: some View {
        SZFastToggleChip(isOn: fastModeEnabled) { onSetFastMode(!fastModeEnabled) }
    }
}

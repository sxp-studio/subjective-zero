// SPDX-License-Identifier: AGPL-3.0-only
// The Experimental pane of the Settings sheet: features still being tried out. Today that is
// Jev, a hosted service that sorts each message you send. Pure SZUI: values in, closures out.
import SwiftUI

public struct SZExperimentalSettingsView: View {
    /// Where the key check stands. Host-owned so it survives switching sections.
    public enum Check: Equatable, Sendable {
        case idle
        case checking
        case verified
        case problem(label: String, detail: String)
    }

    private let jevEnabled: Bool
    /// The saved key, masked; nil = no key saved.
    private let keyHint: String?
    private let check: Check
    private let onSetJevEnabled: (Bool) -> Void
    private let onSaveKey: (String) -> Void
    private let onRemoveKey: () -> Void
    private let onVerify: () -> Void

    @State private var draftKey = ""

    private static let explainer = "Jev is a hosted service that answers quick either-or questions in well under a second. When it's on, Jev sorts each message you send (is it a question, something new to build, or a change to work under way?) instead of your AI provider. If Jev can't answer, your provider sorts the message as before. Jev charges a small amount per message from the balance on your key."

    public init(jevEnabled: Bool, keyHint: String?, check: Check,
                onSetJevEnabled: @escaping (Bool) -> Void,
                onSaveKey: @escaping (String) -> Void,
                onRemoveKey: @escaping () -> Void,
                onVerify: @escaping () -> Void) {
        self.jevEnabled = jevEnabled
        self.keyHint = keyHint
        self.check = check
        self.onSetJevEnabled = onSetJevEnabled
        self.onSaveKey = onSaveKey
        self.onRemoveKey = onRemoveKey
        self.onVerify = onVerify
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Experimental").font(.system(size: 17, weight: .semibold))
            Text("Features we are still trying out. They may change or go away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Text("Jev").font(.system(size: 13, weight: .semibold))
                    SZHelpBubble(text: Self.explainer)
                }
                Toggle("Use Jev to sort messages",
                       isOn: Binding(get: { jevEnabled }, set: { onSetJevEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(keyHint == nil)
                if keyHint == nil {
                    Text("Add a key from jevtypesafe.org to turn this on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                keyRow
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        if let keyHint {
            HStack(spacing: 8) {
                Text("API key")
                    .font(.system(size: 12))
                Text(keyHint)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                checkBadge
                Spacer()
                Button {
                    onVerify()
                } label: {
                    if check == .checking {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Verify")
                    }
                }
                .controlSize(.small)
                .disabled(check == .checking)
                .help("Send one tiny request to Jev to prove the key works. It uses a few tokens")
                Button("Remove") { onRemoveKey() }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                SecureField("API key (jv_live_…)", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 320)
                    .onSubmit(save)
                Button("Save", action: save)
                    .controlSize(.small)
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var checkBadge: some View {
        switch check {
        case .idle, .checking:
            EmptyView()
        case .verified:
            SZSetupBadge(label: "Verified", color: .green)
        case .problem(let label, let detail):
            SZSetupBadge(label: label, color: .red)
            SZCopyableDetailDisclosure(detail: detail)
        }
    }

    private func save() {
        onSaveKey(draftKey)
        draftKey = ""
    }
}

import SwiftUI
import PeekProviders

struct SettingsView: View {

    @Bindable var settings: AppSettings
    let engine: AssistantEngine

    @State private var keyInput: String = ""
    @State private var savedMessage: String?
    @State private var saveError: String?

    private var provider: AssistantProvider { engine.currentProvider() }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $settings.providerID) {
                    Text(provider.displayName).tag(ProviderIdentifier.gemini)
                }
                Picker("Model", selection: $settings.modelID) {
                    ForEach(provider.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }

            Section("API Key") {
                if let masked = engine.maskedKey(for: settings.providerID) {
                    LabeledContent("Stored key") {
                        Text(masked)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // A SecureField, and only ever a masked value is displayed
                // back. This app can screenshot the screen, which makes a
                // visible API key a live hazard rather than a theoretical one.
                SecureField("Paste your API key", text: $keyInput)
                    .onSubmit(save)

                HStack {
                    Button("Save Key", action: save)
                        .disabled(keyInput.isEmpty)
                    if engine.maskedKey(for: settings.providerID) != nil {
                        Button("Remove", action: removeKey)
                    }
                    Spacer()
                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Text("Stored in your macOS Keychain, never in preferences or on disk in plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.providerID == .gemini {
                    Text("Note: on Google's free Gemini tier, your prompts may be used to improve their products. Selected text and screenshots you send are subject to that.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Behaviour") {
                Toggle("Send automatically when invoked with a selection", isOn: $settings.autoSendOnInvoke)
                Text("Off by default. When on, every invocation spends tokens and sends your selection to the provider — including accidental ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use clipboard fallback for unsupported apps", isOn: $settings.clipboardFallbackEnabled)
                Text("Some apps (Electron and Firefox-based, such as Obsidian or Zen) expose no selection to macOS. Peek can briefly copy the selection instead. Your clipboard is restored afterwards, and this never runs in password managers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        do {
            try engine.storeKey(keyInput, for: settings.providerID)
            keyInput = ""
            saveError = nil
            savedMessage = "Saved"
        } catch {
            savedMessage = nil
            saveError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try engine.storeKey("", for: settings.providerID)
            savedMessage = "Removed"
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

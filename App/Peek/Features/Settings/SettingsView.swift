import AppKit
import SwiftUI
import PeekProviders

struct SettingsView: View {

    @Bindable var settings: AppSettings
    let engine: AssistantEngine
    @Bindable var usage: UsageStatisticsViewModel
    let updates: UpdateController

    @State private var keyInput: String = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemBlocked = LoginItem.isBlockedByUser
    @State private var savedMessage: String?
    @State private var saveError: String?

    private var provider: AssistantProvider { engine.currentProvider() }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: Binding(
                    get: { settings.providerID },
                    set: { engine.selectProvider($0) }
                )) {
                    ForEach(engine.availableProviders, id: \.identifier) { candidate in
                        Text(candidate.displayName).tag(candidate.identifier)
                    }
                }

                Picker("Model", selection: $settings.modelID) {
                    ForEach(provider.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .disabled(provider.models.count <= 1)

                if let reason = engine.unavailabilityReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if settings.providerID == .appleIntelligence {
                    Text("Runs entirely on this Mac. Nothing you select or screenshot leaves the device, and no API key is needed. Text only — screenshots need a cloud provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if provider.requiresAPIKey {
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
            }

            Section("Usage") {
                UsageStatisticsView(model: usage)
                    .padding(.vertical, 4)
                Text("Counted from stored conversations, so deleting a conversation removes its usage too. Nothing is reported anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch Peek at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        if LoginItem.setEnabled(newValue) {
                            launchAtLogin = newValue
                        }
                        loginItemBlocked = LoginItem.isBlockedByUser
                    }
                ))
                if loginItemBlocked {
                    Text("Login items are disabled for Peek in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Force Click") {
                if ForceClickTrigger.isSupported {
                    Toggle("Invoke Peek with Force Click", isOn: $settings.forceClickEnabled)

                    Text("Requires a Force Touch trackpad and Accessibility permission. "
                         + "Reads trackpad pressure through a private macOS framework, so a future "
                         + "macOS update could disable it — the keyboard shortcut always keeps working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.forceClickEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Turn off the system's own Look Up, or both will appear at once.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Open Trackpad Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            Text("Trackpad › Point & Click › Look up & data detectors › Off")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("This Mac has no Force Touch trackpad, so Force Click is unavailable. Use \u{2303}\u{2325}Space instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                if updates.isConfigured {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }
                    ))
                    HStack {
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                        Spacer()
                        if let last = updates.lastUpdateCheckDate {
                            Text("Last checked \(last.formatted(.relative(presentation: .numeric)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Updates are downloaded from GitHub Releases and verified against a signing key built into Peek.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This build has no update feed configured, so it will not check for updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behaviour") {
                Toggle("Send automatically when invoked with a selection", isOn: $settings.autoSendOnInvoke)
                Text("Off by default. When on, every invocation spends tokens and sends your selection to the provider — including accidental ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Continue the previous conversation when invoked again from the same app",
                       isOn: $settings.continueRecentConversation)
                Text("Applies within five minutes, and only when the panel is empty. Otherwise each invocation starts fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use clipboard fallback for unsupported apps", isOn: $settings.clipboardFallbackEnabled)
                Text("Some apps (Electron and Firefox-based, such as Obsidian or Zen) expose no selection to macOS. Peek can briefly copy the selection instead. Your clipboard is restored afterwards, and this never runs in password managers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .onAppear { usage.reload() }
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

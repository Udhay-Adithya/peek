import AppKit
import OSLog
import PeekCore
import PeekPersistence

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var hotKeys: HotKeyManager?
    private var settings: AppSettings?
    private var engine: AssistantEngine?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar resident: no Dock icon, no app switcher entry. Paired with
        // LSUIElement so the policy holds from launch rather than flickering.
        NSApp.setActivationPolicy(.accessory)

        // Required even though this app shows no menu bar: AppKit routes ⌘C,
        // ⌘V, ⌘X, ⌘A and ⌘Z through the Edit menu's key equivalents, so
        // without a main menu the panel's text field cannot use the clipboard.
        NSApp.mainMenu = MainMenu.build()

        // Built once, at launch, and reused for every invocation. Panel
        // appearance latency is the number that matters for this product, and
        // constructing an NSPanel plus its SwiftUI hosting view on demand costs
        // far more than positioning and ordering an existing one.
        let settings = AppSettings()
        let engine = AssistantEngine(settings: settings)
        let settingsWindow = SettingsWindowController(settings: settings, engine: engine)
        self.settings = settings
        self.engine = engine
        self.settingsWindow = settingsWindow

        let viewModel = PanelViewModel(settings: settings, engine: engine, store: Self.makeStore())
        let panel = PanelController(viewModel: viewModel)
        self.panel = panel

        // Settings is a conventional, activating window; leaving the
        // non-activating panel floating above it looks broken and steals the
        // keystrokes meant for the key field. Assigned after `panel` exists so
        // the closure can capture it.
        viewModel.onOpenSettings = { [weak panel] in
            panel?.hide()
            settingsWindow.show()
        }

        let statusItem = StatusItemController(
            onPrimaryAction: { [weak panel] in panel?.toggle() },
            onOpenSettings: { [weak panel] in
                panel?.hide()
                settingsWindow.show()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        self.statusItem = statusItem

        // Menu-bar activity indicator, driven by the streaming layer.
        viewModel.session.onStreamingChange = { [weak statusItem] streaming in
            statusItem?.isBusy = streaming
        }

        // Primary trigger. Registration can legitimately fail when another app
        // already owns the shortcut, and a silently dead hotkey is
        // indistinguishable from a broken app, so it is surfaced in the menu
        // bar rather than swallowed.
        let hotKeys = HotKeyManager()
        let registered = hotKeys.register(.defaultInvoke) { [weak panel] in
            panel?.toggle()
        }
        self.hotKeys = hotKeys
        statusItem.hotKeyStatus = registered ? .registered(.defaultInvoke)
                                             : .unavailable(.defaultInvoke)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Conversation storage, falling back to an in-memory store.
    ///
    /// A corrupt or unwritable store must not stop the assistant working; the
    /// user loses history, not the product.
    private static func makeStore() -> ConversationStore {
        let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "persistence")
        do {
            return SwiftDataConversationStore(modelContainer: try PeekModelContainer.makeOnDisk())
        } catch {
            logger.error("on-disk store unavailable, falling back to memory")
            do {
                return SwiftDataConversationStore(modelContainer: try PeekModelContainer.makeInMemory())
            } catch {
                fatalError("SwiftData could not create even an in-memory container")
            }
        }
    }

    /// Target for the ⌘, menu item, reached through the responder chain.
    @objc func openSettingsFromMenu(_ sender: Any?) {
        panel?.hide()
        settingsWindow?.show()
    }
}

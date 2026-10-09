import AppKit
import OSLog
import PeekCore
import PeekCore
import PeekPersistence
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var hotKeys: HotKeyManager?
    private var settings: AppSettings?
    private var engine: AssistantEngine?
    private var router: MainWindowRouter?
    private var services: ServicesProvider?
    private var frontmostTracker: FrontmostAppTracker?
    private var mainWindow: MainWindowController?
    private var updates: UpdateController?
    private var forceClick: ForceClickTrigger?
    private var settingsObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar resident: no Dock icon, no app switcher entry. Paired with
        // LSUIElement so the policy holds from launch rather than flickering.
        NSApp.setActivationPolicy(.accessory)

        // Required even though this app shows no menu bar: AppKit routes ⌘C,
        // ⌘V, ⌘X, ⌘A and ⌘Z through the Edit menu's key equivalents, so
        // without a main menu the panel's text field cannot use the clipboard.
        PerformanceHarness.phase("main menu") { NSApp.mainMenu = MainMenu.build() }

        // Built once, at launch, and reused for every invocation. Panel
        // appearance latency is the number that matters for this product, and
        // constructing an NSPanel plus its SwiftUI hosting view on demand costs
        // far more than positioning and ordering an existing one.
        let settings = PerformanceHarness.phase("AppSettings") { AppSettings() }
        let engine = PerformanceHarness.phase("AssistantEngine") { AssistantEngine(settings: settings) }
        let router = MainWindowRouter()
        self.settings = settings
        self.engine = engine
        self.router = router

        let store = PerformanceHarness.phase("SwiftData container") { Self.makeStore() }
        // Session and history live here, not in a view model: the panel and the
        // expanded window are two views onto one conversation.
        let session = AssistantSession(engine: engine, store: store)
        let history = HistoryViewModel(store: store)
        let usage = UsageStatisticsViewModel(store: store)
        let updates = UpdateController()
        self.updates = updates

        let mainWindow = MainWindowController {
            AnyView(MainWindowView(session: session,
                                   history: history,
                                   router: router,
                                   settings: settings,
                                   usage: usage,
                                   updates: updates,
                                   engine: engine))
        }
        self.mainWindow = mainWindow

        let viewModel = PanelViewModel(settings: settings,
                                       engine: engine,
                                       store: store,
                                       session: session,
                                       history: history)
        let panel = PerformanceHarness.phase("panel pre-warm") { PanelController(viewModel: viewModel) }
        self.panel = panel

        viewModel.onExpand = { [weak panel] in
            panel?.hide()
            mainWindow.show()
        }

        // Settings is a conventional, activating window; leaving the
        // non-activating panel floating above it looks broken and steals the
        // keystrokes meant for the key field. Assigned after `panel` exists so
        // the closure can capture it.
        // Settings is a page in the window now, not a window of its own.
        viewModel.onOpenSettings = { [weak panel] in
            panel?.hide()
            router.pane = .settings
            mainWindow.show()
        }

        viewModel.onShowHistoryInWindow = { [weak panel] in
            panel?.hide()
            router.pane = .conversations
            mainWindow.show()
        }

        // Region capture needs the panel out of the shot, then back.
        viewModel.onRequestHidePanel = { [weak panel] in panel?.hide() }
        viewModel.onRequestShowPanel = { [weak panel] in panel?.showWithoutRecapture() }

        let statusItem = StatusItemController(
            onPrimaryAction: { [weak panel] in panel?.toggle() },
            onOpenSettings: { [weak panel] in
                panel?.hide()
                router.pane = .settings
                mainWindow.show()
            },
            onOpenWindow: { [weak panel] in
                panel?.hide()
                router.pane = .conversations
                mainWindow.show()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        self.statusItem = statusItem

        // Force Click, when the user has switched it on.
        let forceClick = ForceClickTrigger { [weak panel] point in
            // The pressure feed gives the click location; anchor there rather
            // than at wherever the pointer drifted to afterwards.
            panel?.show(anchor: CGRect(origin: point, size: .zero))
        }
        self.forceClick = forceClick
        Self.syncForceClick(forceClick, enabled: settings.forceClickEnabled)

        // Re-evaluated when the setting changes, so toggling takes effect
        // immediately rather than at next launch.
        settingsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.syncForceClick(forceClick, enabled: settings.forceClickEnabled)
            }
        }

        // "Ask Peek" in every app's Services menu — no permissions required.
        let frontmostTracker = FrontmostAppTracker()
        self.frontmostTracker = frontmostTracker

        let services = ServicesProvider(
            sourceApp: { [weak frontmostTracker] in frontmostTracker?.targetApp() },
            onSelection: { [weak panel] text, appName in
                panel?.show(providedText: text, appName: appName)
            },
            onRewrite: { [weak panel] text, action, frontApp in
                panel?.show(rewriteOf: text, action: action, frontApp: frontApp)
            }
        )
        PerformanceHarness.phase("services register") { services.register() }
        self.services = services

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

        PerformanceHarness.recordLaunchComplete()

        if PerformanceHarness.isEnabled {
            Task {
                await PerformanceHarness.runPanelBenchmark(iterations: 60, panel: panel)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Peek is a menu-bar utility, so closing the window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// Drops the Dock icon again once the last ordinary window closes.
    func applicationDidUpdate(_ notification: Notification) {
        mainWindow?.restoreAccessoryPolicyIfNeeded()
    }

    private static func syncForceClick(_ trigger: ForceClickTrigger, enabled: Bool) {
        if enabled {
            if !trigger.isRunning { trigger.start() }
        } else if trigger.isRunning {
            trigger.stop()
        }
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

    /// Target for the "Check for Updates…" menu item.
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        updates?.checkForUpdates()
    }

    /// Target for the ⌘Q menu item.
    ///
    /// Dismisses every surface and returns Peek to the menu bar, leaving the
    /// hotkey, the Services entry and any Force Click trigger live.
    @objc func hideToMenuBar(_ sender: Any?) {
        panel?.hide()
        for window in NSApp.windows where window.isVisible && !(window is PeekPanel) {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Target for the ⌘, menu item, reached through the responder chain.
    @objc func openSettingsFromMenu(_ sender: Any?) {
        panel?.hide()
        router?.pane = .settings
        mainWindow?.show()
    }
}

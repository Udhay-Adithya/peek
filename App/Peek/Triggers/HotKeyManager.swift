import AppKit
import Carbon.HIToolbox

/// Registers the global invocation shortcut and reports presses.
///
/// Carbon delivers hot-key events through a C callback that cannot capture
/// context, so the active manager is reached through a file-scoped reference.
/// It is `nonisolated(unsafe)` because it is written only from the main actor
/// during setup and read only from the Carbon handler, which the Carbon event
/// loop always invokes on the main thread.
@MainActor
final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// Identifies our registration in the Carbon callback. 'peek' as OSType.
    private static let signature: OSType = 0x7065656B

    init() {}

    /// Registers `hotKey`, replacing any previous registration.
    /// - Returns: `false` when another application already owns the shortcut.
    @discardableResult
    func register(_ hotKey: HotKey, onFire: @escaping () -> Void) -> Bool {
        unregister()
        self.onFire = onFire
        activeManager = self

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // Most commonly the shortcut is already taken by another app. The
            // caller surfaces this rather than failing silently, because a
            // dead hotkey is indistinguishable from a broken app to the user.
            self.onFire = nil
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        onFire = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
    }

    fileprivate func fire() {
        onFire?()
    }

    isolated deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        if activeManager === self { activeManager = nil }
    }
}

/// See the note on ``HotKeyManager``: written on the main actor, read only from
/// the Carbon handler which runs on the main thread.
nonisolated(unsafe) private weak var activeManager: HotKeyManager?

private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated {
        activeManager?.fire()
    }
    return noErr
}

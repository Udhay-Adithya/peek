import AppKit
import PeekCore

/// Whether Peek's Services menu entries are actually switched on.
///
/// macOS ships third-party services **disabled by default** and says nothing
/// about it: the entries appear in System Settings unchecked, and until someone
/// ticks them the menu items simply are not there. Nothing distinguishes that
/// from a broken app, so Peek reports it rather than leaving the user to
/// discover it.
enum ServicesAvailability {

    /// One declared service and whether the user has enabled it.
    struct Entry: Identifiable, Equatable {
        let message: String
        let title: String
        let isEnabled: Bool

        var id: String { message }
    }

    /// The services declared in Info.plist, paired with their current state.
    static func entries() -> [Entry] {
        let declared = declaredServices()
        let status = statusDictionary()
        return declared.map { service in
            Entry(message: service.message,
                  title: service.title,
                  isEnabled: isEnabled(message: service.message, in: status))
        }
    }

    static var allEnabled: Bool {
        let all = entries()
        return !all.isEmpty && all.allSatisfy(\.isEnabled)
    }

    static var anyDisabled: Bool {
        entries().contains { !$0.isEnabled }
    }

    /// Reads the service-enablement state macOS keeps in the `pbs` domain.
    private static func statusDictionary() -> [String: Any] {
        UserDefaults(suiteName: "pbs")?
            .dictionary(forKey: "NSServicesStatus") ?? [:]
    }

    /// Matches a service by its `NSMessage`.
    ///
    /// Keys look like `"<bundle id> - <menu title> - <message>"`, so the
    /// message is matched as a suffix: the title is user-visible text that may
    /// be localised or change between versions, while the message is the stable
    /// identifier.
    ///
    /// An absent key means the service is at the system default, and that
    /// default is **off** — so absence is reported as disabled rather than
    /// assumed to be fine.
    static func isEnabled(message: String, in status: [String: Any]) -> Bool {
        guard let entry = status.first(where: { $0.key.hasSuffix(" - \(message)") })?.value,
              let flags = entry as? [String: Any] else {
            return false
        }
        // Either presentation counts: the context menu is where most people
        // will actually reach for it.
        let inServicesMenu = (flags["enabled_services_menu"] as? NSNumber)?.boolValue ?? false
        let inContextMenu = (flags["enabled_context_menu"] as? NSNumber)?.boolValue ?? false
        return inServicesMenu || inContextMenu
    }

    private struct DeclaredService {
        let message: String
        let title: String
    }

    private static func declaredServices() -> [DeclaredService] {
        guard let services = Bundle.main.object(forInfoDictionaryKey: "NSServices")
                as? [[String: Any]] else { return [] }
        return services.compactMap { service in
            guard let message = service["NSMessage"] as? String else { return nil }
            let title = (service["NSMenuItem"] as? [String: Any])?["default"] as? String
            return DeclaredService(message: message, title: title ?? message)
        }
    }

    /// Opens Keyboard settings, where the Services list lives.
    ///
    /// There is no deeper link: the Services list is a sheet inside Keyboard
    /// Shortcuts, and macOS exposes no URL for it, so the UI spells out the
    /// remaining two steps.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

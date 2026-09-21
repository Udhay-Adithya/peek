import AppKit
import Observation
import Sparkle

/// Software updates, via Sparkle.
///
/// Peek ships outside the Mac App Store, so it carries its own updater. Sparkle
/// verifies every update with an EdDSA signature against a public key embedded
/// in the app, which is what makes serving updates from GitHub Releases safe:
/// a compromised download host still cannot deliver a build Peek will install.
///
/// Wrapped rather than used directly, so the rest of the app depends on a small
/// local type instead of a third-party framework, and so an unconfigured feed
/// degrades to "updates unavailable" instead of erroring at the user.
@MainActor
@Observable
final class UpdateController {

    private let updaterController: SPUStandardUpdaterController

    /// False when the build has no feed or public key configured — a local or
    /// unsigned build, where offering an update check would be misleading.
    let isConfigured: Bool

    init() {
        let bundle = Bundle.main
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""

        isConfigured = !feed.isEmpty && !key.isEmpty && !key.hasPrefix("REPLACE_")

        // startingUpdater only when configured, so an unconfigured build does
        // not schedule background checks against a feed that does not exist.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }

    var canCheckForUpdates: Bool {
        isConfigured && updaterController.updater.canCheckForUpdates
    }

    /// Shows Sparkle's own update UI. Always a user action.
    func checkForUpdates() {
        guard isConfigured else { return }
        // Sparkle presents an ordinary window, which an accessory-policy app
        // cannot focus properly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}

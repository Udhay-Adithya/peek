import Testing
import Foundation
import PeekCore

@Suite("DictationLocale")
struct DictationLocaleTests {

    private let supported = [
        Locale(identifier: "en_US"), Locale(identifier: "en_GB"),
        Locale(identifier: "fr_FR"), Locale(identifier: "de_DE"),
        Locale(identifier: "zh_TW"),
    ]

    @Test("matches language and region exactly")
    func exactMatch() {
        let resolved = DictationLocale.resolve(preferred: Locale(identifier: "en_GB"),
                                               supported: supported)
        #expect(resolved?.identifier == "en_GB")
    }

    @Test("ignores a region override carried in the identifier")
    func ignoresRegionOverride() {
        // What a Mac set to US English in India actually reports. Matching the
        // whole identifier finds nothing, which is the bug this guards.
        let preferred = Locale(identifier: "en_US@rg=inzzzz")
        let resolved = DictationLocale.resolve(preferred: preferred, supported: supported)
        #expect(resolved?.identifier == "en_US")
    }

    @Test("ignores calendar and currency extensions")
    func ignoresOtherExtensions() {
        let preferred = Locale(identifier: "fr_FR@calendar=buddhist;currency=jpy")
        let resolved = DictationLocale.resolve(preferred: preferred, supported: supported)
        #expect(resolved?.identifier == "fr_FR")
    }

    @Test("falls back to the same language in another region")
    func fallsBackToLanguage() {
        // en_AU is not offered; dictating in some English beats refusing.
        let resolved = DictationLocale.resolve(preferred: Locale(identifier: "en_AU"),
                                               supported: supported)
        #expect(resolved?.language.languageCode?.identifier == "en")
    }

    @Test("returns nothing when the language is not supported at all")
    func unsupportedLanguage() {
        let resolved = DictationLocale.resolve(preferred: Locale(identifier: "ta_IN"),
                                               supported: supported)
        #expect(resolved == nil)
    }

    @Test("a bare language identifier still matches")
    func bareLanguage() {
        let resolved = DictationLocale.resolve(preferred: Locale(identifier: "de"),
                                               supported: supported)
        #expect(resolved?.identifier == "de_DE")
    }
}

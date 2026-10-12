import Foundation

/// Chooses which speech-recognition locale to dictate in.
///
/// Not as simple as using `Locale.current`: a Mac set to US English in India
/// reports `en-US-u-rg-inzzzz`, and comparing that identifier against the
/// recogniser's supported list matches nothing. Region overrides, calendar and
/// currency extensions all ride along in the identifier, so matching happens on
/// language and region alone.
public enum DictationLocale {

    /// The best supported locale for `preferred`, or `nil` if none fits.
    ///
    /// Returns a locale from `supported` rather than a constructed one, because
    /// the recogniser expects an identifier it actually offers.
    public static func resolve(preferred: Locale, supported: [Locale]) -> Locale? {
        let language = preferred.language.languageCode?.identifier
        let region = preferred.language.region?.identifier

        // Same language and same region — the ordinary case.
        if let language, let region,
           let exact = supported.first(where: {
               $0.language.languageCode?.identifier == language
                   && $0.language.region?.identifier == region
           }) {
            return exact
        }

        // Same language, any region. Dictating US English into a Mac set to
        // en-IN is a far better outcome than refusing to dictate at all.
        if let language,
           let sameLanguage = supported.first(where: {
               $0.language.languageCode?.identifier == language
           }) {
            return sameLanguage
        }

        return nil
    }
}

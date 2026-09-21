import CoreGraphics

/// Sizing rules for images sent to a provider.
///
/// A Retina screenshot is around 6000x4000 pixels. Sent raw it is tens of
/// megabytes, costs a great deal in tokens, and is slower to upload than the
/// answer takes to generate — while adding no accuracy, because providers
/// downscale to roughly this bound anyway.
public enum ImageBudget {

    /// Longest-edge limit, matching what major vision models actually consume.
    public static let maxDimension: CGFloat = 1_568

    /// Warn-level byte size for an encoded attachment.
    public static let softByteLimit = 4 * 1_024 * 1_024

    /// The size to render at, preserving aspect ratio.
    ///
    /// Images already inside the budget are returned unchanged rather than
    /// re-encoded, so a small capture is never needlessly resampled.
    public static func targetSize(for size: CGSize,
                                  maxDimension: CGFloat = ImageBudget.maxDimension) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }

        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return size }

        let scale = maxDimension / longest
        // Never round a dimension down to zero on an extreme aspect ratio.
        return CGSize(width: max(1, (size.width * scale).rounded()),
                      height: max(1, (size.height * scale).rounded()))
    }

    /// Whether an image needs resampling before being sent.
    public static func needsDownscale(_ size: CGSize,
                                      maxDimension: CGFloat = ImageBudget.maxDimension) -> Bool {
        max(size.width, size.height) > maxDimension
    }
}

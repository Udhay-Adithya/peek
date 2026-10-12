import CoreGraphics
import Foundation
import ImageIO
import PeekCore
import UniformTypeIdentifiers

/// Turns a `CGImage` into something small enough to send.
///
/// Shared by screen capture and by images dropped on the menu bar, so both
/// obey the same size budget and produce the same format. Previously this lived
/// inside the screenshot path, which would have meant a dropped 40MB TIFF
/// bypassing the budget entirely.
enum ImageEncoder {

    /// JPEG rather than HEIC: universally accepted by model providers, where
    /// HEIC support varies by vendor.
    private static let quality: CGFloat = 0.8

    /// Downscales within ``ImageBudget`` and encodes.
    static func attachment(from image: CGImage) -> ImageAttachment? {
        let pixelSize = CGSize(width: image.width, height: image.height)
        let target = ImageBudget.targetSize(for: pixelSize)

        let scaled = target == pixelSize ? image : downscale(image, to: target)
        guard let scaled, let data = encodeJPEG(scaled) else { return nil }
        return ImageAttachment(mimeType: "image/jpeg", data: data)
    }

    static func downscale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

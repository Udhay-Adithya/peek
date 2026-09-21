import AppKit
import CoreGraphics
import ImageIO
import OSLog
import PeekCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screen capture via ScreenCaptureKit.
///
/// Only ever invoked from an explicit user action. Screenshots are treated as
/// sensitive throughout: nothing is written to disk, the encoded bytes are the
/// only copy retained, and Peek's own windows are excluded from the capture so
/// the panel never photographs itself.
///
/// The configuration renders at the already-downscaled size rather than
/// capturing full resolution and resampling afterwards, so a 6K display never
/// produces a ~70MB surface at all.
@MainActor
struct ScreenshotService {

    enum Failure: LocalizedError {
        case permissionDenied
        case noDisplay
        case captureFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission is required to capture the screen."
            case .noDisplay:        return "No display available to capture."
            case .captureFailed:    return "The screen capture failed."
            case .encodingFailed:   return "The screenshot could not be encoded."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "screenshot")
    private static let jpegQuality: CGFloat = 0.8

    /// Captures the display containing `point`, or the main display.
    func captureDisplay(containing point: CGPoint? = nil) async throws -> ImageAttachment {
        try await capture(sourceRect: nil, point: point)
    }

    /// Captures a region given in AppKit global (bottom-left origin) coordinates.
    func captureRegion(_ rect: CGRect) async throws -> ImageAttachment {
        guard rect.width >= 1, rect.height >= 1 else { throw Failure.captureFailed }
        return try await capture(sourceRect: rect, point: CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: - Capture

    private func capture(sourceRect: CGRect?, point: CGPoint?) async throws -> ImageAttachment {
        guard ScreenRecordingPermission.isGranted else { throw Failure.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // ScreenCaptureKit reports a revoked grant as a content failure.
            Self.logger.error("shareable content unavailable")
            throw Failure.permissionDenied
        }

        guard let screen = targetScreen(for: point),
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
                  ?? content.displays.first else {
            throw Failure.noDisplay
        }

        // Peek's own windows must not appear in the capture.
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best

        // Region rects arrive in AppKit's bottom-left space; SCStreamConfiguration
        // wants display-local, top-left-origin points.
        let regionInPoints: CGSize
        if let sourceRect {
            let local = Self.displayLocalRect(sourceRect, on: screen)
            configuration.sourceRect = local
            regionInPoints = local.size
        } else {
            regionInPoints = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        }

        // Render straight to the size we intend to send.
        let pixelSize = CGSize(width: regionInPoints.width * screen.backingScaleFactor,
                               height: regionInPoints.height * screen.backingScaleFactor)
        let target = ImageBudget.targetSize(for: pixelSize)
        configuration.width = Int(target.width)
        configuration.height = Int(target.height)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration)
        } catch {
            Self.logger.error("captureImage failed")
            throw Failure.captureFailed
        }

        guard let data = Self.encodeJPEG(image) else { throw Failure.encodingFailed }

        // Byte count only — never the image itself.
        Self.logger.debug("screenshot captured px=\(image.width, privacy: .public)x\(image.height, privacy: .public) bytes=\(data.count, privacy: .public)")
        return ImageAttachment(mimeType: "image/jpeg", data: data)
    }

    // MARK: - Geometry

    private func targetScreen(for point: CGPoint?) -> NSScreen? {
        guard let point else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Converts an AppKit global rect into display-local, top-left-origin points.
    static func displayLocalRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: rect.minX - frame.minX,
                      y: frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    // MARK: - Encoding

    /// JPEG rather than HEIC: universally accepted by model providers, where
    /// HEIC support varies by vendor and would be a per-provider concern.
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }
}

/// Screen Recording permission, requested only when a capture is attempted.
enum ScreenRecordingPermission {

    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. Returns immediately; the grant only takes
    /// effect for subsequent capture attempts.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

struct CaptureResult {
    let shots: [ScreenShot]
    /// Frames of on-screen windows (front to back) in global top-left-origin coordinates, in points.
    let windowFrames: [CGRect]
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required."
        case .noDisplays: return "No displays could be captured."
        }
    }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Captures every attached display at native (Retina) resolution.
    @MainActor
    static func captureAllScreens() async throws -> CaptureResult {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfApp = content.applications.first { $0.processID == selfPID }

        var shots: [ScreenShot] = []
        var usedDisplayIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let matched = content.displays.first(where: { $0.displayID == number })
                ?? content.displays.first(where: { !usedDisplayIDs.contains($0.displayID)
                    && $0.width == Int(screen.frame.width) && $0.height == Int(screen.frame.height) })
            guard let display = matched else {
                NSLog("No SCDisplay for screen %@ (id %@)", screen.localizedName, String(describing: number))
                continue
            }
            usedDisplayIDs.insert(display.displayID)

            let filter: SCContentFilter
            if let selfApp {
                filter = SCContentFilter(display: display, excludingApplications: [selfApp], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }

            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.captureResolution = .best
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        guard !shots.isEmpty else { throw CaptureError.noDisplays }

        let frames = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != selfPID }
            .map(\.frame)
            .filter { $0.width >= 40 && $0.height >= 40 }

        return CaptureResult(shots: shots, windowFrames: frames)
    }
}

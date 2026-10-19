import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

/// An on-screen window. `frame` is in points; global top-left-origin coordinates when it comes from
/// `ScreenCapturer`, and screen-local flipped coordinates inside an `OverlayView`.
struct WindowInfo {
    let windowID: CGWindowID
    var frame: CGRect
    let processID: pid_t
    let bundleID: String?
    let appName: String
    let title: String

    func with(frame: CGRect) -> WindowInfo {
        WindowInfo(windowID: windowID, frame: frame, processID: processID, bundleID: bundleID, appName: appName, title: title)
    }
}

struct CaptureResult {
    let shots: [ScreenShot]
    /// On-screen windows, front to back.
    let windows: [WindowInfo]
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

    /// Finds the SCDisplay for an NSScreen by display ID, falling back to matching by size.
    static func display(for screen: NSScreen, in content: SCShareableContent, used: inout Set<CGDirectDisplayID>) -> SCDisplay? {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let matched = content.displays.first(where: { $0.displayID == number })
            ?? content.displays.first(where: { !used.contains($0.displayID)
                && $0.width == Int(screen.frame.width) && $0.height == Int(screen.frame.height) })
        guard let display = matched else {
            NSLog("No SCDisplay for screen %@ (id %@)", screen.localizedName, String(describing: number))
            return nil
        }
        used.insert(display.displayID)
        return display
    }

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
            guard let display = display(for: screen, in: content, used: &usedDisplayIDs) else { continue }

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

        let windows = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != selfPID }
            .filter { $0.frame.width >= 40 && $0.frame.height >= 40 }
            .map { w in
                WindowInfo(windowID: w.windowID, frame: w.frame, processID: w.owningApplication?.processID ?? 0,
                           bundleID: w.owningApplication?.bundleIdentifier, appName: w.owningApplication?.applicationName ?? "",
                           title: w.title ?? "")
            }

        return CaptureResult(shots: shots, windows: windows)
    }
}

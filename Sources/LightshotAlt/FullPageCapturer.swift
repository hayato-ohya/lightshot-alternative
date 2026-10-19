import AppKit
import ScreenCaptureKit

enum BrowserKind {
    case safari
    case chromium

    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    init?(bundleID: String?) {
        guard let bundleID else { return nil }
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
            self = .safari
        } else if BrowserKind.chromiumBundleIDs.contains(bundleID) {
            self = .chromium
        } else {
            return nil
        }
    }
}

enum FullPageError: LocalizedError {
    case unsupportedApp(String)
    case script(String)
    case windowGone
    case tooLarge(Int, Int)
    case noProgress

    var errorDescription: String? {
        switch self {
        case .unsupportedApp(let name):
            return "\"\(name)\" is not supported. Full-page capture works with Safari and Chromium browsers (Chrome, Edge, Brave, Arc, Vivaldi, Opera)."
        case .script(let message):
            if message.localizedCaseInsensitiveContains("javascript") || message.contains("-1743") || message.contains("-10000") {
                return "The browser refused to run JavaScript.\n\nSafari: enable Develop → Allow JavaScript from Apple Events.\nChrome: View → Developer → Allow JavaScript from Apple Events.\n\n(\(message))"
            }
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not allowed") {
                return "Automation permission is required. Allow Lightshot Alternative to control the browser in System Settings → Privacy & Security → Automation.\n\n(\(message))"
            }
            return "Could not talk to the browser: \(message)"
        case .windowGone: return "The browser window is no longer on screen."
        case .tooLarge(let w, let h): return "The page is too large to capture (\(w) × \(h) pixels)."
        case .noProgress: return "The page could not be scrolled. Pages that scroll inside an inner element are not supported."
        }
    }
}

/// One viewport capture, in device pixels of the final image.
struct PageSlice {
    let image: CGImage      // already cropped to the viewport (minus the top inset for slices after the first)
    let y: Int              // destination y (top-left origin) in the composite
}

struct PageMetrics: Decodable {
    let sh: Double      // scrollHeight (CSS px)
    let ih: Double      // innerHeight
    let iw: Double      // innerWidth
    let sy: Double      // current scrollY
    let dpr: Double     // devicePixelRatio (includes page zoom)
    let top: Double     // height of fixed/sticky header area (CSS px)
    let bottom: Double  // height of fixed footer area (CSS px)
}

/// Captures a whole web page by scrolling a Safari / Chromium window and stitching viewport captures.
@MainActor
final class FullPageCapturer {
    let window: WindowInfo
    let kind: BrowserKind
    var onProgress: ((Int, Int) -> Void)?

    init(window: WindowInfo) throws {
        guard let kind = BrowserKind(bundleID: window.bundleID) else {
            throw FullPageError.unsupportedApp(window.appName.isEmpty ? (window.bundleID ?? "Unknown") : window.appName)
        }
        self.window = window
        self.kind = kind
    }

    func capture() async throws -> CGImage {
        if let app = NSRunningApplication(processIdentifier: window.processID) {
            app.activate()
            try await Task.sleep(for: .milliseconds(350))
        }
        let metrics = try await run(js: FullPageCapturer.metricsJS, decode: PageMetrics.self)
        let dpr = metrics.dpr
        let viewportW = Int((metrics.iw * dpr).rounded())
        let viewportH = Int((metrics.ih * dpr).rounded())
        let totalH = Int((metrics.sh * dpr).rounded())
        guard viewportW > 0, viewportH > 0, totalH > 0 else { throw FullPageError.noProgress }
        guard viewportW * totalH <= 250_000_000 else { throw FullPageError.tooLarge(viewportW, totalH) }

        var top = metrics.top, bottom = metrics.bottom
        if top + bottom > metrics.ih * 0.7 { top = 0; bottom = 0 }
        let step = max(metrics.ih - top - bottom, metrics.ih * 0.25)
        let estimatedSlices = Int(((metrics.sh - metrics.ih) / step).rounded(.up)) + 1

        var slices: [PageSlice] = []
        var desiredY = 0.0
        var lastY = -1.0
        defer { Task { _ = try? await run(js: FullPageCapturer.scrollJS(to: metrics.sy)) } }

        for index in 0..<400 {
            let actualY = Double(try await run(js: FullPageCapturer.scrollJS(to: desiredY))) ?? desiredY
            if index > 0 && actualY <= lastY + 0.5 { break }
            lastY = actualY
            try await Task.sleep(for: .milliseconds(index == 0 ? 150 : 250))
            onProgress?(index + 1, max(estimatedSlices, index + 1))

            let shot = try await captureWindowImage()
            let topInset = index == 0 ? 0 : Int((top * dpr).rounded())
            guard let slice = FullPageCapturer.cropViewport(shot, viewportW: viewportW, viewportH: viewportH,
                                                            topInset: topInset, rightAligned: kind == .safari) else { continue }
            slices.append(PageSlice(image: slice, y: Int((actualY * dpr).rounded()) + topInset))

            if actualY + metrics.ih >= metrics.sh - 1 { break }
            desiredY = actualY + step
        }
        guard !slices.isEmpty else { throw FullPageError.noProgress }
        guard let composite = FullPageCapturer.compose(slices, width: viewportW, height: totalH) else {
            throw FullPageError.tooLarge(viewportW, totalH)
        }
        return composite
    }

    // MARK: - Window capture

    private func captureWindowImage() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw FullPageError.windowGone
        }
        let frame = scWindow.frame
        let scale = FullPageCapturer.screen(containing: frame)?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int((frame.width * scale).rounded())
        config.height = Int((frame.height * scale).rounded())
        config.captureResolution = .best
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// `frame` is in global top-left-origin coordinates.
    private static func screen(containing frame: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    /// Cuts the page viewport out of a window image. The viewport sits at the bottom of the window
    /// (below the toolbar); a sidebar shifts it to the right in Safari and leaves it left-aligned in Chrome.
    nonisolated static func cropViewport(_ image: CGImage, viewportW: Int, viewportH: Int, topInset: Int, rightAligned: Bool) -> CGImage? {
        let w = min(viewportW, image.width)
        let h = min(viewportH, image.height)
        let x = (abs(image.width - w) <= 2 || !rightAligned) ? 0 : image.width - w
        let y = image.height - h + topInset
        guard h - topInset > 0 else { return nil }
        return image.cropping(to: CGRect(x: x, y: y, width: w, height: h - topInset))
    }

    // MARK: - Stitching

    /// Draws slices top to bottom into one image (top-left origin for `PageSlice.y`). Later slices overwrite earlier ones.
    nonisolated static func compose(_ slices: [PageSlice], width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        for slice in slices {
            let h = slice.image.height
            let destY = height - slice.y - h  // flip to CG's bottom-left origin
            ctx.draw(slice.image, in: CGRect(x: 0, y: destY, width: slice.image.width, height: h))
        }
        return ctx.makeImage()
    }

    // MARK: - Browser scripting

    static let metricsJS = """
    (function(){var d=document,e=d.scrollingElement||d.documentElement,ih=window.innerHeight,iw=window.innerWidth,top=0,bottom=0;\
    var all=d.querySelectorAll('body *');for(var i=0;i<all.length;i++){var el=all[i],cs=getComputedStyle(el),p=cs.position;\
    if(p!=='fixed'&&p!=='sticky')continue;if(cs.visibility==='hidden'||cs.display==='none'||parseFloat(cs.opacity)===0)continue;\
    var r=el.getBoundingClientRect();if(r.height<=0||r.width<iw*0.3)continue;\
    if(r.top<=2&&r.bottom<ih*0.4)top=Math.max(top,r.bottom);if(r.bottom>=ih-2&&r.top>ih*0.6)bottom=Math.max(bottom,ih-r.top);}\
    return JSON.stringify({sh:e.scrollHeight,ih:ih,iw:iw,sy:window.scrollY||e.scrollTop,dpr:window.devicePixelRatio,top:Math.round(top),bottom:Math.round(bottom)});})()
    """

    static func scrollJS(to y: Double) -> String {
        "(function(y){var e=document.scrollingElement||document.documentElement;e.style.scrollBehavior='auto';window.scrollTo({top:y,left:0,behavior:'instant'});return String(window.scrollY||e.scrollTop);})(\(y))"
    }

    private func run<T: Decodable>(js: String, decode: T.Type) async throws -> T {
        let text = try await run(js: js)
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw FullPageError.script("unexpected result: \(text.prefix(200))")
        }
        return value
    }

    /// Runs JavaScript in the picked window's active tab and returns the result as text.
    private func run(js: String) async throws -> String {
        let source = FullPageCapturer.appleScript(kind: kind, bundleID: window.bundleID ?? "", windowTitle: window.title, js: js)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: FullPageError.script("could not compile script"))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
                    continuation.resume(throwing: FullPageError.script("\(message) (\(number))"))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    nonisolated static func appleScript(kind: BrowserKind, bundleID: String, windowTitle: String, js: String) -> String {
        let jsLiteral = escaped(js)
        let titleLiteral = escaped(windowTitle)
        switch kind {
        case .safari:
            return """
            tell application id "\(bundleID)"
                set theWindow to front window
                if "\(titleLiteral)" is not "" then
                    try
                        set theWindow to first window whose name is "\(titleLiteral)"
                    end try
                end if
                return (do JavaScript "\(jsLiteral)" in current tab of theWindow) as text
            end tell
            """
        case .chromium:
            return """
            tell application id "\(bundleID)"
                set theWindow to front window
                if "\(titleLiteral)" is not "" then
                    try
                        set theWindow to first window whose title is "\(titleLiteral)"
                    end try
                end if
                return (execute active tab of theWindow javascript "\(jsLiteral)") as text
            end tell
            """
        }
    }

    nonisolated static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

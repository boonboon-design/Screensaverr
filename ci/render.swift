// CI smoke test: loads the built .saver like legacyScreenSaver does, points it at the mock
// servers, lets it run, and saves screenshots of the screen saver and its Options sheet.
//
//   swiftc ci/render.swift -o build/render
//   build/render build/Release/Screensaverr.saver out/ 18989 40

import AppKit
import ScreenSaver

setvbuf(stdout, nil, _IONBF, 0)

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: render <Screensaverr.saver> <output dir> <mock port> [seconds]")
    exit(2)
}
let bundlePath = arguments[1]
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let port = arguments[3]
let seconds = arguments.count > 4 ? Double(arguments[4]) ?? 30 : 30
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

// MARK: Settings, written exactly where the screen saver reads them.

let base = "http://127.0.0.1:\(port)"
let settings: [String: Any] = [
    "sonarr": ["url": "\(base)/sonarr", "apiKey": "testkey"],
    "radarr": ["url": "\(base)/radarr/", "apiKey": "testkey"],
    "seerr": ["url": "127.0.0.1:\(port)/seerr", "apiKey": "testkey"],
    "sabnzbd": ["url": "\(base)/sab", "apiKey": "testkey"],
    "tvDaysAhead": 7,
    "movieDaysAhead": 60,
    "requestCount": 8,
    "showBackdrop": true,
]
let json = String(data: try JSONSerialization.data(withJSONObject: settings), encoding: .utf8)!
let bundle = Bundle(path: bundlePath)!
let moduleName = bundle.bundleIdentifier!
let defaults = ScreenSaverDefaults(forModuleWithName: moduleName)!
defaults.set(json, forKey: "settings.v1")
defaults.synchronize()
print("module: \(moduleName)")

// MARK: Load the bundle.

try bundle.loadAndReturnError()
guard let saverClass = bundle.principalClass as? ScreenSaverView.Type else {
    print("error: principal class \(String(describing: bundle.principalClass)) is not a ScreenSaverView")
    exit(1)
}
print("principal class: \(saverClass)")

/// `[[cls alloc] initWithFrame:isPreview:]`, which is exactly what legacyScreenSaver does.
/// (Swift can't call a non-required initializer through a metatype.)
@MainActor
func makeSaver(_ frame: NSRect) -> ScreenSaverView? {
    let selector = NSSelectorFromString("initWithFrame:isPreview:")
    guard let allocated = (saverClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
    else { return nil }
    typealias Initializer = @convention(c) (AnyObject, Selector, NSRect, ObjCBool) -> Unmanaged<ScreenSaverView>?
    let initializer = unsafeBitCast(allocated.method(for: selector), to: Initializer.self)
    return initializer(allocated, selector, frame, true)?.takeRetainedValue()
}

// MARK: Capture helpers

typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// CGWindowListCreateImage is unavailable in the macOS 15 SDK but still present at runtime,
/// and capturing our own windows needs no screen-recording permission.
@MainActor
func captureWindow(_ window: NSWindow) -> CGImage? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let function = unsafeBitCast(symbol, to: WindowListCreateImage.self)
    // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3 (image option)
    return function(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
}

@MainActor
func renderLayers(_ view: NSView) -> CGImage? {
    guard let layer = view.layer else { return nil }
    let scale = view.window?.backingScaleFactor ?? 1
    let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    layer.render(in: context)
    return context.makeImage()
}

@MainActor
func isMostlyEmpty(_ image: CGImage) -> Bool {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
    let length = CFDataGetLength(data)
    var bright = 0
    var index = 0
    while index < length {
        if bytes[index] > 60 || bytes[index + 1] > 60 || bytes[index + 2] > 60 { bright += 1 }
        index += 4 * 97
    }
    return bright < 20
}

@MainActor
func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let url = outputDirectory.appendingPathComponent(name)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("saved \(url.path) (\(image.width)x\(image.height))")
}

/// Prints a small JPEG as base64 so the screenshot can be read straight from the CI log.
@MainActor
func printPreview(_ image: CGImage, _ name: String, width: Int) {
    let height = Int(Double(width) * Double(image.height) / Double(image.width))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let small = context.makeImage(),
          let jpeg = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    else { return }
    print("BEGIN-PREVIEW \(name) \(jpeg.count)")
    let encoded = jpeg.base64EncodedString()
    var start = encoded.startIndex
    while start < encoded.endIndex {
        let end = encoded.index(start, offsetBy: 2000, limitedBy: encoded.endIndex) ?? encoded.endIndex
        print("PREVIEW:" + encoded[start..<end])
        start = end
    }
    print("END-PREVIEW \(name)")
}

@MainActor
func pump(_ duration: TimeInterval) {
    let until = Date().addingTimeInterval(duration)
    while Date() < until {
        RunLoop.main.run(mode: .default, before: min(until, Date().addingTimeInterval(0.1)))
    }
}

@MainActor
func shoot(_ window: NSWindow, _ name: String, previewWidth: Int) {
    window.displayIfNeeded()
    CATransaction.flush()
    pump(0.5)
    var image = captureWindow(window)
    if let captured = image, isMostlyEmpty(captured) {
        print("window capture of \(name) looks empty; falling back to layer rendering")
        image = nil
    }
    if image == nil, let content = window.contentView { image = renderLayers(content) }
    guard let image else {
        print("error: could not capture \(name)")
        return
    }
    save(image, name + ".png")
    printPreview(image, name, width: previewWidth)
}

// MARK: Full-screen saver

let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
guard let saver = makeSaver(frame) else {
    print("error: init(frame:isPreview:) returned nil")
    exit(1)
}
window.contentView = saver
window.setFrameOrigin(.zero)
window.orderFrontRegardless()
saver.startAnimation()
print("running for \(Int(seconds))s…")
pump(seconds)
shoot(window, "screensaver", previewWidth: 1280)

// MARK: System Settings-sized preview

let thumbFrame = NSRect(x: 0, y: 0, width: 296, height: 184)
let thumbWindow = NSWindow(contentRect: thumbFrame, styleMask: [.borderless], backing: .buffered, defer: false)
thumbWindow.isReleasedWhenClosed = false
if let thumb = makeSaver(thumbFrame) {
    thumbWindow.contentView = thumb
    thumbWindow.setFrameOrigin(NSPoint(x: 0, y: 1100))
    thumbWindow.orderFrontRegardless()
    thumb.startAnimation()
    pump(3)
    shoot(thumbWindow, "preview-thumbnail", previewWidth: 296)
    thumb.stopAnimation()
}

// MARK: Options sheet

if saver.hasConfigureSheet, let sheet = saver.configureSheet {
    sheet.setFrameOrigin(NSPoint(x: 100, y: 100))
    sheet.orderFrontRegardless()
    pump(2)
    shoot(sheet, "options-sheet", previewWidth: 560)
} else {
    print("error: no configure sheet")
    exit(1)
}

saver.stopAnimation()
print("done")
exit(0)

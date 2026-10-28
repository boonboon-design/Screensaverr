// CI smoke test: loads the built .saver like legacyScreenSaver does, points it at the mock
// servers, lets it run, and saves screenshots of the screen saver and its Options sheet.
//
//   swiftc ci/render.swift -o build/render
//   build/render build/Release/Screensaverr.saver out/ 18989 40

import AppKit
import ScreenSaver
import Security

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

// MARK: Settings, written exactly where the screen saver reads them.

let base = "http://127.0.0.1:\(port)"
let settings: [String: Any] = [
    "sonarr": ["url": "\(base)/sonarr", "apiKey": "testkey"],
    "radarr": ["url": "\(base)/radarr/", "apiKey": "testkey"],
    "seerr": ["url": "127.0.0.1:\(port)/seerr", "apiKey": "testkey"],
    "sabnzbd": ["url": "\(base)/sab", "apiKey": "testkey"],
    "tautulli": ["url": "\(base)/tautulli", "apiKey": "testkey"],
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

/// Lets the run loop (timers, network callbacks, Core Animation) run for a while.
@MainActor
func pause(_ duration: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
}

@MainActor
func shoot(_ window: NSWindow, _ name: String) async {
    window.displayIfNeeded()
    CATransaction.flush()
    await pause(0.5)
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
}

@MainActor
func findView(named name: String, in view: NSView) -> NSView? {
    if String(describing: type(of: view)) == name { return view }
    for subview in view.subviews {
        if let found = findView(named: name, in: subview) { return found }
    }
    return nil
}

/// The part of a window capture covered by `view`.
@MainActor
func crop(_ image: CGImage, to view: NSView, in window: NSWindow) -> CGImage? {
    let rect = view.convert(view.bounds, to: nil)
    let scale = CGFloat(image.width) / window.frame.width
    let pixels = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                        width: rect.width * scale, height: rect.height * scale).integral
    return image.cropping(to: pixels)
}

/// Lays frames out left to right, top to bottom.
@MainActor
func contactSheet(_ frames: [CGImage], columns: Int) -> CGImage? {
    guard let first = frames.first else { return nil }
    let gap = 8, frameWidth = first.width, frameHeight = first.height
    let rows = (frames.count + columns - 1) / columns
    let width = columns * frameWidth + (columns + 1) * gap
    let height = rows * frameHeight + (rows + 1) * gap
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, frame) in frames.enumerated() {
        let column = index % columns, row = index / columns
        context.draw(frame, in: CGRect(x: gap + column * (frameWidth + gap), y: height - (row + 1) * (frameHeight + gap),
                                       width: frameWidth, height: frameHeight))
    }
    return context.makeImage()
}

// MARK: Scenes

@MainActor
func runScenes() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    // Full-screen saver
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
    await pause(seconds)
    await shoot(window, "screensaver")

    // The mock has three streams, more than Now Playing fits, so its list glides between them.
    // Film the box for a few seconds, across at least one glide, as a contact sheet.
    if let box = findView(named: "NowPlayingView", in: saver) {
        var frames: [CGImage] = []
        for _ in 0..<16 {
            if let image = captureWindow(window), let frame = crop(image, to: box, in: window) { frames.append(frame) }
            await pause(0.35)
        }
        if let sheet = contactSheet(frames, columns: 4) { save(sheet, "now-playing-scroll.png") }
    } else {
        print("warning: NowPlayingView not found")
    }

    // System Settings-sized preview
    let thumbFrame = NSRect(x: 0, y: 0, width: 296, height: 184)
    let thumbWindow = NSWindow(contentRect: thumbFrame, styleMask: [.borderless], backing: .buffered, defer: false)
    thumbWindow.isReleasedWhenClosed = false
    if let thumb = makeSaver(thumbFrame) {
        thumbWindow.contentView = thumb
        thumbWindow.setFrameOrigin(NSPoint(x: 0, y: 1100))
        thumbWindow.orderFrontRegardless()
        thumb.startAnimation()
        await pause(3)
        await shoot(thumbWindow, "preview-thumbnail")
        thumb.stopAnimation()
    }

    // Options sheet
    guard saver.hasConfigureSheet, let sheet = saver.configureSheet else {
        print("error: no configure sheet")
        exit(1)
    }
    sheet.setFrameOrigin(NSPoint(x: 100, y: 100))
    sheet.orderFrontRegardless()
    await pause(2)
    await shoot(sheet, "options-sheet")

    saver.stopAnimation()

    // The plain-text keys written above must have moved into the Keychain and out of the file.
    defaults.synchronize()
    let preferences = defaults.string(forKey: "settings.v1") ?? ""
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: moduleName,
        kSecAttrAccount as String: "sonarr",
        kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    let keychainKey = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    print("preferences still contain API keys: \(preferences.contains("testkey"))")
    print("Keychain lookup for the Sonarr key: status \(status), matches: \(keychainKey == "testkey")")
    guard !preferences.contains("testkey"), keychainKey == "testkey" else {
        print("error: API keys were not moved into the Keychain")
        exit(1)
    }

    print("done")
    exit(0)
}

Task { @MainActor in
    await runScenes()
}
RunLoop.main.run()

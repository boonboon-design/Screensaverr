import AppKit
import ScreenSaver

/// The screen saver's principal class (see `NSPrincipalClass` in Info.plist).
@objc(ScreensaverrView)
final class ScreensaverrView: ScreenSaverView {
    private var dashboard: DashboardView?
    private var isActive = false
    private var detectedPreview = false
    private lazy var settingsController = SettingsWindowController()

    private static var didConfigureSharedServices = false

    override init?(frame: NSRect, isPreview: Bool) {
        // legacyScreenSaver passes isPreview = true for every instance (FB7486243), so
        // decide from the size instead: the System Settings thumbnail is tiny.
        let preview = frame.width < 640 || frame.height < 400
        super.init(frame: frame, isPreview: preview)
        detectedPreview = preview
        Log.general.info("init frame=\(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public) preview=\(preview, privacy: .public) (reported \(isPreview, privacy: .public))")
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        detectedPreview = isPreview
        setUp()
    }

    private func setUp() {
        Self.configureSharedServices()
        animationTimeInterval = 1
        wantsLayer = true

        let dashboard = DashboardView(frame: bounds)
        dashboard.autoresizingMask = [.width, .height]
        addSubview(dashboard)
        self.dashboard = dashboard

        if !detectedPreview {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(screenSaverWillStop(_:)),
                name: Notification.Name("com.apple.screensaver.willstop"),
                object: nil
            )
        }
    }

    private static func configureSharedServices() {
        guard !didConfigureSharedServices else { return }
        didConfigureSharedServices = true
        DashboardStore.shared.settingsLoader = { SettingsStore.load() }
        ImageStore.shared.apiKeyProvider = { kind in
            let key = DashboardStore.shared.settings[kind].trimmedAPIKey
            return key.isEmpty ? nil : key
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: ScreenSaverView

    override func startAnimation() {
        super.startAnimation()
        activate()
    }

    override func stopAnimation() {
        super.stopAnimation()
        deactivate()
    }

    /// Drawing happens in layer-backed subviews driven by our own timers.
    override func animateOneFrame() {}

    override func draw(_ rect: NSRect) {
        Theme.background.setFill()
        rect.fill()
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? { settingsController.makeWindow() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { deactivate() }
    }

    // MARK: Activity

    private func activate() {
        guard !isActive else { return }
        isActive = true
        DashboardStore.shared.activate()
        dashboard?.start()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        dashboard?.stop()
        DashboardStore.shared.deactivate()
    }

    /// Since macOS 14, stopAnimation() isn't called when the screen saver is dismissed and the
    /// legacyScreenSaver process keeps every old instance alive, still running. This
    /// notification is the only reliable signal, and exiting the host process is the only
    /// reliable cleanup (the same workaround Aerial and Apple's forums recommend).
    @objc private func screenSaverWillStop(_ notification: Notification) {
        Log.general.info("willstop received; exiting host shortly")
        deactivate()
        DashboardStore.shared.shutdown()
        if #available(macOS 14.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                exit(0)
            }
        }
    }
}

import AppKit
import QuartzCore

/// Full-screen artwork that slowly pans and zooms (Ken Burns), cross-fading between images,
/// under a dark gradient so the text on top stays readable.
final class BackdropView: NSView {
    private let baseLayer = CAGradientLayer()
    private let imageContainer = CALayer()
    private let dimLayer = CAGradientLayer()
    private var imageLayers: [CALayer] = []
    private(set) var currentKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true

        baseLayer.colors = [
            NSColor(srgbRed: 0.06, green: 0.08, blue: 0.13, alpha: 1).cgColor,
            Theme.background.cgColor,
        ]
        baseLayer.startPoint = CGPoint(x: 0.5, y: 1)
        baseLayer.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(baseLayer)
        root.addSublayer(imageContainer)

        // Layer-hosting views are not flipped: y = 1 is the top of the screen.
        dimLayer.colors = [
            NSColor.black.withAlphaComponent(0.93).cgColor,
            NSColor.black.withAlphaComponent(0.74).cgColor,
            NSColor.black.withAlphaComponent(0.62).cgColor,
            NSColor.black.withAlphaComponent(0.80).cgColor,
        ]
        dimLayer.locations = [0, 0.38, 0.72, 1]
        dimLayer.startPoint = CGPoint(x: 0.5, y: 0)
        dimLayer.endPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(dimLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = bounds
        imageContainer.frame = bounds
        dimLayer.frame = bounds
        for imageLayer in imageLayers {
            imageLayer.bounds = CGRect(origin: .zero, size: overscanSize)
            imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }

    private var overscanSize: CGSize {
        CGSize(width: bounds.width * 1.12, height: bounds.height * 1.12)
    }

    /// Cross-fades to `image` (or back to the plain gradient when nil).
    func show(_ image: NSImage?, key: String?) {
        guard key != currentKey else { return }
        currentKey = key

        let outgoing = imageLayers
        imageLayers = []

        CATransaction.begin()
        CATransaction.setAnimationDuration(2.5)
        CATransaction.setCompletionBlock {
            for old in outgoing { old.removeFromSuperlayer() }
        }

        for old in outgoing {
            old.opacity = 0
        }

        if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let incoming = CALayer()
            incoming.contents = cgImage
            incoming.contentsGravity = .resizeAspectFill
            incoming.bounds = CGRect(origin: .zero, size: overscanSize)
            incoming.position = CGPoint(x: bounds.midX, y: bounds.midY)
            incoming.opacity = 0
            imageContainer.addSublayer(incoming)
            imageLayers = [incoming]

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 2.5
            incoming.add(fade, forKey: "fadeIn")
            incoming.opacity = 1

            incoming.add(kenBurns(), forKey: "kenBurns")
        }
        CATransaction.commit()
    }

    private func kenBurns() -> CAAnimation {
        let drift = CGFloat.random(in: -1...1)
        let start = CATransform3DMakeScale(1.0, 1.0, 1)
        var end = CATransform3DMakeScale(1.07, 1.07, 1)
        end = CATransform3DTranslate(end, bounds.width * 0.025 * drift, bounds.height * 0.015, 0)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: end)
        animation.duration = 48
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

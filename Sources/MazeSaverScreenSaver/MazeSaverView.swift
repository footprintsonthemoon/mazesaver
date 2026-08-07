import ScreenSaver

/// The screensaver host's ScreenSaverView subclass. Not built via SwiftPM — the
/// `.saver` bundle is compiled directly from this file plus the MazeCore sources
/// via Scripts/build-saver.sh, so everything lands in one compilation unit (no
/// `import MazeCore` needed, same as how the app target used to be a single target
/// before it was split for reuse).
@objc(MazeSaverScreenSaverView)
public final class MazeSaverScreenSaverView: ScreenSaverView {
    private var mazeView: MazeView?
    private let cellSize: CGFloat = 24

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
    }

    /// `bounds` can be 0x0 (or, on some external/non-Retina setups, in backing
    /// pixels rather than points) the moment the view is created, before the host
    /// has actually sized it — fall back to the screen size in that case.
    private func targetSize() -> NSSize {
        if bounds.width > 1, bounds.height > 1 { return bounds.size }
        return window?.screen?.frame.size ?? NSScreen.main?.frame.size ?? NSSize(width: 1920, height: 1080)
    }

    private func installMazeViewIfNeeded() {
        guard mazeView == nil else { return }
        let size = targetSize()
        let cols = max(Int(size.width / cellSize), 10)
        let rows = max(Int(size.height / cellSize), 8)

        let engine = MazeEngine(cols: cols, rows: rows)
        let view = MazeView(engine: engine, cellSize: cellSize)
        view.frame = (bounds.width > 1 && bounds.height > 1) ? bounds : NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        mazeView = view
    }

    public override func startAnimation() {
        super.startAnimation()
        installMazeViewIfNeeded()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        // Each System Settings preview spins up a fresh instance that isn't always
        // reliably released — drop our subview explicitly rather than relying on it.
        mazeView?.removeFromSuperview()
        mazeView = nil
    }

    public override func animateOneFrame() {
        mazeView?.tick(dt: animationTimeInterval)
    }

    public override func layout() {
        super.layout()
        if let mazeView, mazeView.frame != bounds {
            mazeView.frame = bounds
        }
    }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }
}

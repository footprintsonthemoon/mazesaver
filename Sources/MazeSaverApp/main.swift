import AppKit
import MazeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mazeView: MazeView!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cellSize: CGFloat = 24
        let cols = 44
        let rows = 30

        let engine = MazeEngine(cols: cols, rows: rows)
        mazeView = MazeView(engine: engine, cellSize: cellSize)

        window = NSWindow(
            contentRect: mazeView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MazeSaver"
        window.contentView = mazeView
        window.contentMinSize = NSSize(width: cellSize * 10, height: cellSize * 8 + 88)
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.mazeView.tick(dt: 1.0 / 60.0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

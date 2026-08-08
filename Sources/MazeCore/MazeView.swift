import AppKit

public final class MazeView: NSView {
    private var engine: MazeEngine
    private let cellSize: CGFloat
    private let headerHeight: CGFloat = 44
    private let footerHeight: CGFloat = 44

    private let headerColor = NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.04, alpha: 1)
    /// Entrance/exit markers are always this color — a fixed, functional signal
    /// ("start"/"goal"), independent of the ambient theme or whatever's resting on them.
    private let markerColor = NSColor(calibratedRed: 0.3, green: 1.0, blue: 0.45, alpha: 1)

    /// Ambient palette (background/walls) — cycles every `themeInterval` mazes so a
    /// screensaver running for hours doesn't stay visually static. Algorithm accent
    /// colors (and the entrance/exit markers) stay constant across themes since
    /// they're functional color codes, not decoration.
    private struct Theme {
        let name: String
        let background: NSColor
        let wall: NSColor
    }

    private let themes: [Theme] = [
        Theme(name: "Midnight", background: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.07, alpha: 1),
              wall: NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 0.9)),
        Theme(name: "Sunset", background: NSColor(calibratedRed: 0.08, green: 0.03, blue: 0.05, alpha: 1),
              wall: NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.35, alpha: 0.9)),
        Theme(name: "Matrix", background: NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.02, alpha: 1),
              wall: NSColor(calibratedRed: 0.3, green: 1.0, blue: 0.4, alpha: 0.85)),
        Theme(name: "Frost", background: NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 1),
              wall: NSColor(calibratedRed: 0.75, green: 0.92, blue: 1.0, alpha: 0.9))
    ]
    private let themeInterval = 8

    private func theme(for mazeGeneration: Int) -> Theme {
        themes[(mazeGeneration / themeInterval) % themes.count]
    }

    /// Tracks which runners we've already fired a confetti burst for, so it only
    /// fires once per runner per maze.
    private var previousFinished: [Bool] = []
    /// How far into each runner's visitedOrder we've already scanned for dead-end
    /// backtrack jumps (see `spawnDeadEndPuffs`).
    private var lastScannedIndex: [Int] = []
    /// Whether the exit-found flourish has already fired for this maze.
    private var exitFoundFlashed = false
    /// Seconds since the exit-found flourish fired — drives the marker's little
    /// pop-and-settle bounce. `.infinity` while idle/long done.
    private var exitFoundAge: Double = .infinity
    private let exitFoundPopDuration: Double = 0.5
    private let exitFoundRingDuration: Double = 0.7
    /// Whether the maze was fully built last tick — used to detect the instant
    /// construction finishes, which starts the appear-delay countdown.
    private var exitMazeWasFullyBuilt = false
    /// Counts up once the maze is fully built; once it reaches
    /// `exitAppearDelayDuration`, `exitWaitingAge` starts. `.infinity` while idle.
    private var exitAppearDelay: Double = .infinity
    private let exitAppearDelayDuration: Double = 2.0
    /// Seconds since the exit marker started actually appearing (after the delay
    /// above) — drives its fade-in and the repeating "still waiting to be found"
    /// pulse, separate from the one-shot found ring. `.infinity` until then.
    private var exitWaitingAge: Double = .infinity
    private let exitWaitingPulsePeriod: Double = 1.1
    private let exitFadeInDuration: Double = 0.5
    private var lastSeenGeneration = -1
    private var particles: [Particle] = []
    private var puffs: [Puff] = []

    /// Walls the "under construction" reveal has opened so far — incrementally
    /// updated as `engine.builtCount` advances, one carve step at a time.
    private var builtOpenWalls: Set<WallKey> = []
    private var lastBuiltCount = 0
    /// The carve step index at which each cell first becomes part of the maze —
    /// used so unreached cells draw no walls at all during `.building` (a blank
    /// void the maze grows into) instead of a dense fully-walled grid from frame one.
    private var revealedCellIndex: [GridPos: Int] = [:]

    private struct WallKey: Hashable {
        let pos: GridPos
        let dir: Direction
    }

    private static func computeRevealedCellIndex(entrance: EdgeOpening, grid: MazeGrid, carveSteps: [CarveStep]) -> [GridPos: Int] {
        var result: [GridPos: Int] = [:]
        result[grid.position(of: entrance)] = 0
        for (i, step) in carveSteps.enumerated() {
            if let next = grid.neighbor(of: step.from, direction: step.direction) {
                result[next] = i + 1
            }
        }
        return result
    }

    private struct Particle {
        var position: NSPoint
        var velocity: NSPoint
        var life: CGFloat
        let maxLife: CGFloat
        let color: NSColor
        /// Tiny glinting particles spawned around the ball while it travels, as
        /// opposed to a one-off confetti burst — drawn smaller, with a glow.
        var isSparkle: Bool = false
    }

    /// A small fading ring marking a dead end the search just backtracked from.
    private struct Puff {
        let position: NSPoint
        var life: CGFloat
        let maxLife: CGFloat
        let color: NSColor
    }

    /// Each search algorithm gets its own accent color, used for the frontier
    /// highlight, the visited-cell tint, the ball, and its comet trail, so it's
    /// obvious at a glance which algorithm is currently running (or racing).
    private func accentColor(for kind: SearchAlgorithmKind) -> NSColor {
        switch kind {
        case .depthFirst: return NSColor(calibratedRed: 0.3, green: 0.7, blue: 1.0, alpha: 1)
        case .breadthFirst: return NSColor(calibratedRed: 0.35, green: 0.9, blue: 0.45, alpha: 1)
        case .aStar: return NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.95, alpha: 1)
        case .wallFollower: return NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.15, alpha: 1)
        case .randomWalk: return NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.35, alpha: 1)
        }
    }

    public init(engine: MazeEngine, cellSize: CGFloat) {
        self.engine = engine
        self.cellSize = cellSize
        let size = NSSize(width: CGFloat(engine.cols) * cellSize, height: CGFloat(engine.rows) * cellSize + headerHeight + footerHeight)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var isFlipped: Bool { true }

    /// Rebuilds the engine at the grid size implied by the view's current bounds,
    /// so the maze always fills the window (or, later, the actual screen) instead
    /// of being stuck at whatever size it was created with.
    private func regenerateEngineIfNeeded() {
        // The legacyScreenSaver host can hand out `bounds` in backing pixels rather
        // than points on some external/non-Retina display setups. Clamping against
        // the actual screen size (always in points) keeps that from generating a
        // wildly oversized grid that only partially fits on screen.
        var size = bounds.size
        if let screenSize = window?.screen?.frame.size, screenSize.width > 1, screenSize.height > 1 {
            size.width = min(size.width, screenSize.width)
            size.height = min(size.height, screenSize.height)
        }

        let availableHeight = max(size.height - headerHeight - footerHeight, cellSize)
        let newCols = max(Int(size.width / cellSize), 4)
        let newRows = max(Int(availableHeight / cellSize), 4)
        guard newCols != engine.cols || newRows != engine.rows else { return }
        engine = MazeEngine(cols: newCols, rows: newRows)
    }

    public override func layout() {
        super.layout()
        regenerateEngineIfNeeded()
    }

    /// Advances the simulation by `dt` seconds and redraws. The view itself owns no
    /// timer — each host drives this at whatever cadence fits it: the standalone
    /// app with its own `Timer`, the screensaver via `ScreenSaverView.animateOneFrame()`.
    public func tick(dt: Double) {
        engine.tick(dt: dt)
        updateEffects(dt: dt)
        needsDisplay = true
    }

    private func rect(for pos: GridPos) -> NSRect {
        NSRect(x: CGFloat(pos.col) * cellSize, y: CGFloat(pos.row) * cellSize + headerHeight, width: cellSize, height: cellSize)
    }

    private func screenPoint(forRunner index: Int) -> NSPoint {
        let (col, row) = engine.ballPosition(runnerIndex: index)
        return NSPoint(x: CGFloat(col) * cellSize + cellSize / 2, y: CGFloat(row) * cellSize + cellSize / 2 + headerHeight)
    }

    /// Which runners are actually shown right now. During a race's search (and the
    /// settling pause right after) that's everyone; once actual travel starts,
    /// only the winner continues.
    private func activeRunnerIndices() -> [Int] {
        if engine.isRace, engine.phase == .traveling || engine.phase == .arrived || engine.phase == .wrapping {
            return engine.winnerRunnerIndex.map { [$0] } ?? Array(engine.runners.indices)
        }
        return Array(engine.runners.indices)
    }

    /// Advances the confetti/puff particle systems. Runs once per tick, independent
    /// of drawing, so it isn't tied to how often `draw` happens to fire.
    private func updateEffects(dt: Double) {
        if engine.mazeGeneration != lastSeenGeneration || previousFinished.count != engine.runners.count {
            lastSeenGeneration = engine.mazeGeneration
            previousFinished = Array(repeating: false, count: engine.runners.count)
            lastScannedIndex = Array(repeating: 0, count: engine.runners.count)
            builtOpenWalls = []
            lastBuiltCount = 0
            exitFoundFlashed = false
            exitFoundAge = .infinity
            exitMazeWasFullyBuilt = false
            exitAppearDelay = .infinity
            exitWaitingAge = .infinity
            revealedCellIndex = MazeView.computeRevealedCellIndex(entrance: engine.entrance, grid: engine.grid, carveSteps: engine.carveSteps)
        }

        // The instant the maze finishes building, start a 2-second countdown
        // during which the exit stays completely invisible — only after that does
        // it start fading in and pulsing "still waiting to be found".
        let mazeFullyBuiltNow = isMazeFullyBuilt()
        if mazeFullyBuiltNow, !exitMazeWasFullyBuilt {
            exitAppearDelay = 0
        }
        exitMazeWasFullyBuilt = mazeFullyBuiltNow

        if exitAppearDelay < .infinity, exitWaitingAge == .infinity {
            exitAppearDelay += dt
            if exitAppearDelay >= exitAppearDelayDuration {
                exitWaitingAge = 0
            }
        }
        if exitWaitingAge < .infinity, !exitFound() {
            exitWaitingAge += dt
        }

        // A theatrical little flourish right as the exit marker flips from green
        // to the algorithm's color — the moment the path is actually found: a
        // bigger confetti burst, a bright expanding ring, and the marker itself
        // pops past its normal size before settling back (see `drawMarkers` /
        // `drawExitFoundRing`).
        if !exitFoundFlashed, exitFound() {
            exitFoundFlashed = true
            exitFoundAge = 0
            let color = currentLeadKind().map(accentColor(for:)) ?? markerColor
            let exitCenter = rect(for: engine.grid.position(of: engine.exit))
            spawnConfetti(at: NSPoint(x: exitCenter.midX, y: exitCenter.midY), color: color, count: 48, speedRange: 90...240)
        }
        if exitFoundAge < .infinity {
            exitFoundAge += dt
        }

        while lastBuiltCount < engine.builtCount {
            let step = engine.carveSteps[lastBuiltCount]
            builtOpenWalls.insert(WallKey(pos: step.from, dir: step.direction))
            if let neighbor = engine.grid.neighbor(of: step.from, direction: step.direction) {
                builtOpenWalls.insert(WallKey(pos: neighbor, dir: step.direction.opposite))
            }
            lastBuiltCount += 1
        }

        let active = Set(activeRunnerIndices())
        for i in engine.runners.indices {
            let runner = engine.runners[i]

            if active.contains(i), !previousFinished[i], runner.finished {
                previousFinished[i] = true
                spawnConfetti(at: screenPoint(forRunner: i), color: accentColor(for: runner.kind))
            }

            if engine.phase == .searching {
                spawnDeadEndPuffs(runnerIndex: i)
            }

            if engine.phase == .traveling, active.contains(i), Double.random(in: 0..<1) < 0.35 {
                let tint = NSColor.white.blended(withFraction: 0.35, of: accentColor(for: runner.kind)) ?? .white
                spawnSparkle(at: screenPoint(forRunner: i), color: tint)
            }
        }

        for idx in particles.indices {
            particles[idx].position.x += particles[idx].velocity.x * CGFloat(dt)
            particles[idx].position.y += particles[idx].velocity.y * CGFloat(dt)
            particles[idx].velocity.x *= 0.94
            particles[idx].velocity.y *= 0.94
            particles[idx].life -= CGFloat(dt)
        }
        particles.removeAll { $0.life <= 0 }

        for idx in puffs.indices {
            puffs[idx].life -= CGFloat(dt)
        }
        puffs.removeAll { $0.life <= 0 }
    }

    /// A "jump" between two consecutive cells in the recorded visit order — i.e.
    /// they aren't actually adjacent in the maze — means the search abandoned a
    /// dead end and resumed somewhere else in the frontier. Mark the abandoned
    /// cell with a small puff. (Physically-stepping algorithms like the wall
    /// follower never produce such jumps, so this only fires for DFS/BFS/A*.)
    private func spawnDeadEndPuffs(runnerIndex i: Int) {
        guard i < lastScannedIndex.count else { return }
        let runner = engine.runners[i]
        let order = runner.searchResult.visitedOrder
        let upTo = runner.revealedCount - 1
        guard upTo > lastScannedIndex[i] else { return }

        let color = accentColor(for: runner.kind)
        for j in lastScannedIndex[i]..<upTo {
            let from = order[j]
            let to = order[j + 1]
            if !engine.grid.passableNeighbors(of: from).contains(to) {
                let r = rect(for: from)
                puffs.append(Puff(position: NSPoint(x: r.midX, y: r.midY), life: 0.4, maxLife: 0.4, color: color))
            }
        }
        lastScannedIndex[i] = upTo
    }

    private func spawnConfetti(at point: NSPoint, color: NSColor, count: Int = 24, speedRange: ClosedRange<CGFloat> = 60...170) {
        for _ in 0..<count {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: speedRange)
            let velocity = NSPoint(x: cos(angle) * speed, y: sin(angle) * speed)
            let life = CGFloat.random(in: 0.5...0.9)
            particles.append(Particle(position: point, velocity: velocity, life: life, maxLife: life, color: color))
        }
    }

    /// One or two tiny glints near `point`, popping briefly then fading — the
    /// "sparkly" twinkle that follows the ball as it travels the found path.
    private func spawnSparkle(at point: NSPoint, color: NSColor) {
        for _ in 0..<Int.random(in: 1...2) {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let dist = CGFloat.random(in: 0...(cellSize * 0.4))
            let offset = NSPoint(x: point.x + cos(angle) * dist, y: point.y + sin(angle) * dist)
            let speed = CGFloat.random(in: 5...20)
            let velocity = NSPoint(x: cos(angle) * speed, y: sin(angle) * speed)
            let life = CGFloat.random(in: 0.2...0.4)
            particles.append(Particle(position: offset, velocity: velocity, life: life, maxLife: life, color: color, isSparkle: true))
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let currentTheme = theme(for: engine.mazeGeneration)
        currentTheme.background.setFill()
        ctx.fill(bounds)

        if engine.phase == .arriving {
            drawArrivalPing(ctx)
            drawHeader()
            drawFooter()
            return
        }

        if engine.phase == .wrapping {
            drawWrapAnimation(ctx)
            drawHeader()
            drawFooter()
            return
        }

        drawVisitedCells(ctx)
        drawPuffs(ctx)
        if engine.phase == .building {
            let builtCount = engine.builtCount
            drawWalls(ctx, grid: engine.grid, cols: engine.cols, rows: engine.rows, color: currentTheme.wall, hasWallOverride: { [grid = engine.grid, builtOpenWalls, revealedCellIndex] pos, dir in
                let posRevealed = (revealedCellIndex[pos] ?? .max) <= builtCount
                let neighborRevealed = grid.neighbor(of: pos, direction: dir).map { (revealedCellIndex[$0] ?? .max) <= builtCount } ?? false
                guard posRevealed || neighborRevealed else { return false }
                return !builtOpenWalls.contains(WallKey(pos: pos, dir: dir))
            })
        } else {
            drawWalls(ctx, grid: engine.grid, cols: engine.cols, rows: engine.rows, color: currentTheme.wall)
        }
        // Markers drawn before the ball: a resting ball (its own true or blending
        // color) should show on top rather than being masked by the marker
        // underneath it. During .building, still gated to cells the construction
        // has actually reached.
        if engine.phase == .building {
            let builtCount = engine.builtCount
            drawMarkers(ctx, grid: engine.grid, entrance: engine.entrance, exit: engine.exit, revealFilter: { [revealedCellIndex] pos in
                (revealedCellIndex[pos] ?? .max) <= builtCount
            })
        } else {
            drawMarkers(ctx, grid: engine.grid, entrance: engine.entrance, exit: engine.exit)
        }
        drawTravelTrail(ctx)
        drawBalls(ctx)
        // Shown through the search and the settling pause, gone once travel starts.
        if let winner = engine.winnerRunnerIndex, engine.phase == .searching || engine.phase == .settling {
            drawWinnerBanner(ctx, runnerIndex: winner)
        }
        drawStatsBanner(ctx)

        drawConfetti(ctx)
        drawHeader()
        drawFooter()
    }

    private func drawVisitedCells(_ ctx: CGContext) {
        // Left in place through settling and the travel itself — the search isn't
        // erased, the solution trail simply gets drawn on top of it. Also drawn
        // (explicitly, by drawWrapAnimation) during the brief .wrapping fade-out.
        guard engine.phase == .searching || engine.phase == .settling || engine.phase == .traveling || engine.phase == .arrived || engine.phase == .wrapping else { return }
        // Kept short so the head ball (drawn later, on top) reads as the "current
        // position" marker instead of blending into a long trail of bright squares.
        let frontierWindow = 3
        let inset = cellSize * 0.12
        // A square's corners poke out past an inscribed circle, so once the exit
        // has actually been found, its highlight square would show past the edges
        // of the ball resting there — exclude it, the ball alone is enough.
        let hiddenPos = exitFound() ? engine.grid.position(of: engine.exit) : nil

        for runner in engine.runners {
            let order = runner.searchResult.visitedOrder
            let revealed = runner.revealedCount
            guard revealed > 0 else { continue }
            let accent = accentColor(for: runner.kind)
            let frontierColor = accent.withAlphaComponent(0.85)
            let frontierStart = max(0, revealed - frontierWindow)

            // How many times each cell has been visited so far. DFS/BFS/A* never
            // revisit a cell, so this is a no-op for them — but the wall follower
            // and random walk genuinely backtrack over the same ground, and that's
            // now shown deliberately (brighter with each extra visit) instead of
            // being an accidental side effect of overdrawing translucent fills.
            var visitCounts: [GridPos: Int] = [:]
            for i in 0..<frontierStart {
                visitCounts[order[i], default: 0] += 1
            }

            for (pos, count) in visitCounts where pos != hiddenPos {
                let alpha = min(0.75, 0.35 + 0.12 * CGFloat(count - 1))
                accent.withAlphaComponent(alpha).setFill()
                ctx.fill(rect(for: pos).insetBy(dx: inset, dy: inset))
            }

            for i in frontierStart..<revealed where order[i] != hiddenPos {
                frontierColor.setFill()
                ctx.fill(rect(for: order[i]).insetBy(dx: inset, dy: inset))
            }
        }
    }

    /// Draws the solved path from the entrance up to the ball's current position —
    /// no separate "preview" pass, the trail simply grows as the ball actually
    /// walks it.
    private func drawTravelTrail(_ ctx: CGContext) {
        guard engine.phase == .traveling || engine.phase == .arrived || engine.phase == .wrapping else { return }

        for i in activeRunnerIndices() {
            let runner = engine.runners[i]
            let path = runner.searchResult.path
            guard path.count > 1 else { continue }

            let maxProgress = Double(path.count - 1)
            let progress = min(runner.pathProgress, maxProgress)
            let fullCount = min(Int(progress), path.count - 1)
            let t = progress - Double(fullCount)

            let bp = NSBezierPath()
            bp.lineWidth = max(2, cellSize * 0.15)
            bp.lineCapStyle = .round
            bp.lineJoinStyle = .round

            for idx in 0...fullCount {
                let r = rect(for: path[idx])
                let center = NSPoint(x: r.midX, y: r.midY)
                if idx == 0 { bp.move(to: center) } else { bp.line(to: center) }
            }
            if fullCount < path.count - 1 {
                let a = rect(for: path[fullCount])
                let b = rect(for: path[fullCount + 1])
                bp.line(to: NSPoint(x: a.midX + (b.midX - a.midX) * CGFloat(t), y: a.midY + (b.midY - a.midY) * CGFloat(t)))
            }

            accentColor(for: runner.kind).setStroke()
            bp.stroke()
        }
    }

    private func drawWalls(_ ctx: CGContext, grid: MazeGrid, cols: Int, rows: Int, color: NSColor, hasWallOverride: ((GridPos, Direction) -> Bool)? = nil) {
        color.setStroke()
        ctx.setLineWidth(max(1.5, cellSize * 0.08))
        ctx.setLineCap(.round)
        ctx.beginPath()

        func hasWall(_ pos: GridPos, _ dir: Direction) -> Bool {
            hasWallOverride?(pos, dir) ?? grid.hasWall(pos, dir)
        }

        for row in 0..<rows {
            for col in 0..<cols {
                let pos = GridPos(col: col, row: row)
                let r = rect(for: pos)
                if hasWall(pos, .north) {
                    ctx.move(to: CGPoint(x: r.minX, y: r.minY))
                    ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                }
                if hasWall(pos, .west) {
                    ctx.move(to: CGPoint(x: r.minX, y: r.minY))
                    ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                }
                // Only the last row/column need to draw their south/east walls;
                // interior south/east walls are shared with the next cell's north/west.
                if row == rows - 1, hasWall(pos, .south) {
                    ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
                    ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                }
                if col == cols - 1, hasWall(pos, .east) {
                    ctx.move(to: CGPoint(x: r.maxX, y: r.minY))
                    ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                }
            }
        }
        ctx.strokePath()
    }

    /// The current maze's lead algorithm (the winner once a race is decided,
    /// otherwise the sole runner) — used to color the entrance marker and the
    /// exit marker once it's been reached.
    private func currentLeadKind() -> SearchAlgorithmKind? {
        let i = engine.leadRunnerIndex
        if engine.runners.indices.contains(i) { return engine.runners[i].kind }
        return engine.runners.first?.kind
    }

    /// True once the path to the exit has actually been *found* — not once the
    /// ball has walked there. In a race that's the moment a winner is decided;
    /// otherwise once the search reveal reaches the goal (i.e. `.settling` onward).
    private func exitFound() -> Bool {
        engine.winnerRunnerIndex != nil || engine.phase == .settling || engine.phase == .traveling || engine.phase == .arrived
    }

    /// Whether the maze itself is fully built and on screen right now — false
    /// during `.building` (still under construction), and during
    /// `.arriving`/`.wrapping` when no maze/markers are shown at all.
    private func isMazeFullyBuilt() -> Bool {
        switch engine.phase {
        case .arriving, .wrapping, .building:
            return false
        default:
            return true
        }
    }

    /// The entrance marker always matches the current algorithm's color; the exit
    /// marker stays green — a beacon for "not found yet" — until the search
    /// actually finds it, at which point it takes on the algorithm's color too.
    private func drawMarkers(_ ctx: CGContext, grid: MazeGrid, entrance: EdgeOpening, exit: EdgeOpening, revealFilter: ((GridPos) -> Bool)? = nil) {
        let entrancePos = grid.position(of: entrance)
        let exitPos = grid.position(of: exit)
        let leadColor = currentLeadKind().map(accentColor(for:)) ?? markerColor
        let baseRadius = cellSize * 0.42

        // The exit briefly pops past its normal size and settles back right when
        // it's found — a little punctuation for the moment, not a permanent change.
        let exitPopScale: CGFloat = {
            guard exitFoundAge < exitFoundPopDuration else { return 1 }
            let t = CGFloat(exitFoundAge / exitFoundPopDuration)
            return 1 + 0.7 * (1 - t) * (1 - t)
        }()

        // Eases in rather than popping straight to full opacity the instant
        // construction reaches it.
        let exitFadeAlpha: CGFloat = exitWaitingAge < .infinity ? CGFloat(min(1, exitWaitingAge / exitFadeInDuration)) : 0
        let exitColor = (exitFound() ? leadColor : markerColor).withAlphaComponent(exitFadeAlpha)

        for (pos, color, radius) in [(entrancePos, leadColor, baseRadius), (exitPos, exitColor, baseRadius * exitPopScale)] {
            guard revealFilter?(pos) ?? true else { continue }
            color.setFill()
            let center = rect(for: pos)
            let r = NSRect(x: center.midX - radius, y: center.midY - radius, width: radius * 2, height: radius * 2)
            NSBezierPath(ovalIn: r).fill()
        }

        drawExitFoundRing(ctx, color: leadColor)
        drawExitWaitingPulse(ctx)
    }

    /// A gentle, repeating expanding ring around the still-green exit marker,
    /// starting the instant it first appears — so it reads as "still waiting to
    /// be found" instead of just abruptly popping into existence and sitting there.
    /// Stops the moment the path is actually found (the one-shot ring takes over).
    private func drawExitWaitingPulse(_ ctx: CGContext) {
        guard exitWaitingAge < .infinity, !exitFound() else { return }
        let pos = engine.grid.position(of: engine.exit)
        let center = rect(for: pos)
        let mid = NSPoint(x: center.midX, y: center.midY)

        let phaseInPulse = exitWaitingAge.truncatingRemainder(dividingBy: exitWaitingPulsePeriod) / exitWaitingPulsePeriod
        let baseRadius = cellSize * 0.42
        let ringRadius = baseRadius + cellSize * 0.9 * CGFloat(phaseInPulse)
        let fadeAlpha = CGFloat(min(1, exitWaitingAge / exitFadeInDuration))
        let ringAlpha = (1 - CGFloat(phaseInPulse)) * 0.6 * fadeAlpha

        markerColor.withAlphaComponent(ringAlpha).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: mid.x - ringRadius, y: mid.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = max(1.5, cellSize * 0.06)
        ring.stroke()
    }

    /// A bright, one-shot expanding-and-fading ring at the exit, launched the
    /// instant the path is found — the "ta-da" moment.
    private func drawExitFoundRing(_ ctx: CGContext, color: NSColor) {
        guard exitFoundAge < exitFoundRingDuration else { return }
        let pos = engine.grid.position(of: engine.exit)
        let r = rect(for: pos)
        let center = NSPoint(x: r.midX, y: r.midY)

        let t = CGFloat(exitFoundAge / exitFoundRingDuration)
        let radius = cellSize * 0.42 + cellSize * 1.8 * t
        color.withAlphaComponent((1 - t) * 0.85).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ring.lineWidth = max(2, cellSize * 0.1) * (1 - t * 0.6)
        ring.stroke()
    }

    /// The `.arriving` phase: just the entrance point sitting there, with a
    /// quiet, repeating ping ring — before any maze structure is drawn at all.
    /// Still in the *previous* maze's algorithm color; it only eases into the new
    /// one during `.building` (see `ballColor(for:)`).
    private func drawArrivalPing(_ ctx: CGContext) {
        let color = engine.previousLeadKind.map(accentColor(for:)) ?? markerColor
        let pos = engine.grid.position(of: engine.entrance)
        let r = rect(for: pos)
        let center = NSPoint(x: r.midX, y: r.midY)
        let markerRadius = cellSize * 0.42

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - markerRadius, y: center.y - markerRadius, width: markerRadius * 2, height: markerRadius * 2)).fill()

        let pulsePeriod = 0.9
        let maxPulseRadius = cellSize * 1.4
        let phaseInPulse = engine.arrivingElapsed.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        let ringRadius = markerRadius + (maxPulseRadius - markerRadius) * CGFloat(phaseInPulse)
        let ringAlpha = (1 - CGFloat(phaseInPulse)) * 0.7

        color.withAlphaComponent(ringAlpha).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = max(1.5, cellSize * 0.06)
        ring.stroke()
    }

    /// Outward screen-space direction for a border side (`isFlipped`, so "north"
    /// — up, toward row 0 — is -y, matching how `rect(for:)` lays out rows).
    private func screenDirection(for side: Side) -> (dx: CGFloat, dy: CGFloat) {
        switch side {
        case .west: return (-1, 0)
        case .east: return (1, 0)
        case .north: return (0, -1)
        case .south: return (0, 1)
        }
    }

    /// The `.wrapping` phase: the maze is gone entirely — just the pulsing ball,
    /// sliding off the exit edge while its mirror slides in from the opposite
    /// edge (the new maze's entrance side), landing exactly where `.arriving`'s
    /// ping will pick it up.
    private let wrapFadeOutDuration: Double = 0.6
    /// A calm beat after the fade-out — just the pulsing ball sitting still —
    /// before it actually starts sliding toward the edge.
    private let wrapPauseDuration: Double = 1.0

    private func drawWrapAnimation(_ ctx: CGContext) {
        guard let pendingGrid = engine.pendingGrid, let pendingEntrance = engine.pendingEntrance else { return }

        // The old maze gently fades out rather than cutting away instantly — just
        // for the first beat of the wrap, underneath the ball animation.
        if engine.wrapElapsed < wrapFadeOutDuration {
            let currentTheme = theme(for: engine.mazeGeneration)
            let alpha = 1 - CGFloat(engine.wrapElapsed / wrapFadeOutDuration)
            ctx.saveGState()
            ctx.setAlpha(alpha)
            drawVisitedCells(ctx)
            drawWalls(ctx, grid: engine.grid, cols: engine.cols, rows: engine.rows, color: currentTheme.wall)
            drawMarkers(ctx, grid: engine.grid, entrance: engine.entrance, exit: engine.exit)
            drawTravelTrail(ctx)
            drawBalls(ctx)
            ctx.restoreGState()
        }

        // Still the current maze's algorithm color — it only starts easing toward
        // the new maze's algorithm once building begins (see `ballColor(for:)`).
        let color = currentLeadKind().map(accentColor(for:)) ?? markerColor

        let dir = screenDirection(for: engine.exit.side)
        let exitRest = rect(for: engine.grid.position(of: engine.exit))
        let exitRestPoint = NSPoint(x: exitRest.midX, y: exitRest.midY)
        let entranceRest = rect(for: pendingGrid.position(of: pendingEntrance))
        let entranceRestPoint = NSPoint(x: entranceRest.midX, y: entranceRest.midY)

        // Fade out, then a beat of stillness (just pulsing in place), and only
        // then does it actually start sliding — the pause matters as much as the
        // motion for making this read as deliberate rather than rushed.
        let slideStart = wrapFadeOutDuration + wrapPauseDuration
        let slideDuration = max(0.1, engine.wrapTotalDuration - slideStart)
        let t = CGFloat(min(1, max(0, engine.wrapElapsed - slideStart) / slideDuration))
        let farDistance = cellSize * 3
        let exitPoint = NSPoint(x: exitRestPoint.x + dir.dx * farDistance * t, y: exitRestPoint.y + dir.dy * farDistance * t)
        let entrancePoint = NSPoint(x: entranceRestPoint.x - dir.dx * farDistance * (1 - t), y: entranceRestPoint.y - dir.dy * farDistance * (1 - t))

        let baseRadius = cellSize * 0.42
        // Pulses continuously through the whole phase (fade, pause, and slide)
        // rather than tracking slide progress, which would freeze it during the pause.
        let pulse = 1 + 0.18 * sin(engine.wrapElapsed * 6)
        let radius = baseRadius * CGFloat(pulse)

        for point in [exitPoint, entrancePoint] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: cellSize * 0.9, color: color.cgColor)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            ctx.restoreGState()
        }
    }

    /// During `.building`, the ball eases from the *previous* maze's algorithm
    /// color into this one's over the course of the animation, instead of
    /// snapping straight to it. Every other phase just shows the current color.
    private func ballColor(for runner: Runner) -> NSColor {
        let newColor = accentColor(for: runner.kind)
        guard engine.phase == .building, let oldKind = engine.previousLeadKind else { return newColor }
        let blend = engine.carveSteps.isEmpty ? 1 : CGFloat(engine.builtCount) / CGFloat(engine.carveSteps.count)
        return accentColor(for: oldKind).blended(withFraction: blend, of: newColor) ?? newColor
    }

    private func drawBalls(_ ctx: CGContext) {
        // Color alone identifies the algorithm now (header/footer, markers, ball
        // all agree), so no floating name tag is needed. Size stays constant
        // throughout (matching the markers) except for the race side-by-side bump.
        let showRaceStyling = engine.isRace && (engine.phase == .searching || engine.phase == .settling)

        for i in activeRunnerIndices() {
            let runner = engine.runners[i]
            let color = ballColor(for: runner)
            let center = screenPoint(forRunner: i)
            let baseRadius: CGFloat = 0.42
            let radius = cellSize * (showRaceStyling ? baseRadius * 1.15 : baseRadius)
            let ballRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: cellSize * 0.75, color: color.cgColor)
            color.setFill()
            NSBezierPath(ovalIn: ballRect).fill()
            ctx.restoreGState()
        }
    }

    private func drawWinnerBanner(_ ctx: CGContext, runnerIndex: Int) {
        guard runnerIndex < engine.runners.count else { return }
        let color = accentColor(for: engine.runners[runnerIndex].kind)
        let text = "\(engine.runners[runnerIndex].kind.shortName) WINS!" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .heavy),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attrs)
        let mazeAreaHeight = bounds.height - headerHeight - footerHeight
        let boxHeight = size.height + 18
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: headerHeight + (mazeAreaHeight - boxHeight) / 2 + 10)
        let backing = NSRect(x: origin.x - 18, y: origin.y - 10, width: size.width + 36, height: boxHeight)

        NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: backing, xRadius: 10, yRadius: 10).fill()
        color.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(roundedRect: backing, xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        border.stroke()

        text.draw(at: origin, withAttributes: attrs)
    }

    private struct StatSegment {
        let text: String
        let color: NSColor
    }
    private struct StatRow {
        let label: String
        let segments: [StatSegment]
    }
    private struct MeasuredPart {
        let text: String
        let color: NSColor
        let x: CGFloat
    }

    /// Rows shared between racers (maze size, path length — identical either way,
    /// since a perfect maze has exactly one route) are shown once; rows that
    /// differ per algorithm (cells searched, search efficiency) list one colored
    /// value per runner side by side.
    private func statRows() -> [StatRow] {
        let total = engine.cols * engine.rows
        let labelColor = NSColor(calibratedWhite: 0.85, alpha: 0.9)

        guard engine.isRace else {
            guard let runner = engine.runners.first else { return [] }
            let visited = runner.searchResult.visitedOrder.count
            let pathLen = runner.searchResult.path.count
            let pct = visited > 0 ? Double(pathLen) / Double(visited) * 100 : 0
            let color = accentColor(for: runner.kind)
            return [
                StatRow(label: "all:", segments: [StatSegment(text: "\(total)", color: color)]),
                StatRow(label: "searched:", segments: [StatSegment(text: "\(visited)", color: color)]),
                StatRow(label: "path:", segments: [StatSegment(text: "\(pathLen)", color: color)]),
                StatRow(label: "track/path:", segments: [StatSegment(text: "\(Int(pct.rounded()))%", color: color)])
            ]
        }

        let runners = engine.runners
        let pathLen = runners.first?.searchResult.path.count ?? 0
        return [
            StatRow(label: "all:", segments: [StatSegment(text: "\(total)", color: labelColor)]),
            StatRow(label: "path:", segments: [StatSegment(text: "\(pathLen)", color: labelColor)]),
            StatRow(label: "searched:", segments: runners.map {
                StatSegment(text: "\($0.searchResult.visitedOrder.count)", color: accentColor(for: $0.kind))
            }),
            StatRow(label: "track/path:", segments: runners.map { r in
                let visited = r.searchResult.visitedOrder.count
                let pct = visited > 0 ? Double(r.searchResult.path.count) / Double(visited) * 100 : 0
                return StatSegment(text: "\(Int(pct.rounded()))%", color: accentColor(for: r.kind))
            })
        ]
    }

    private func drawStatsBanner(_ ctx: CGContext) {
        guard engine.phase == .arrived else { return }
        let rows = statRows()
        guard !rows.isEmpty else { return }

        // Shrink the font until the box fits the available space, so this never
        // runs off the edge of a narrow or short window/screen.
        let padding: CGFloat = 22
        let sideMargin: CGFloat = 24
        let mazeAreaHeight = bounds.height - headerHeight - footerHeight
        let maxBoxWidth = max(bounds.width - sideMargin * 2, 40)
        let maxBoxHeight = max(mazeAreaHeight - 40, 30)
        let labelColor = NSColor(calibratedWhite: 0.85, alpha: 0.9)
        let gapAfterLabel: CGFloat = 8
        let gapBetweenSegments: CGFloat = 18

        var fontSize: CGFloat = 22
        let minFontSize: CGFloat = 8
        func font(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) }

        func measureRow(_ row: StatRow, font f: NSFont) -> (width: CGFloat, parts: [MeasuredPart]) {
            var parts: [MeasuredPart] = []
            var x: CGFloat = 0
            let labelSize = (row.label as NSString).size(withAttributes: [.font: f])
            parts.append(MeasuredPart(text: row.label, color: labelColor, x: x))
            x += labelSize.width + gapAfterLabel
            for (i, seg) in row.segments.enumerated() {
                let segSize = (seg.text as NSString).size(withAttributes: [.font: f])
                parts.append(MeasuredPart(text: seg.text, color: seg.color, x: x))
                x += segSize.width
                if i < row.segments.count - 1 { x += gapBetweenSegments }
            }
            return (x, parts)
        }

        func measure(_ size: CGFloat) -> (rows: [(width: CGFloat, parts: [MeasuredPart])], boxWidth: CGFloat, boxHeight: CGFloat, lineHeight: CGFloat) {
            let f = font(size)
            let measured = rows.map { measureRow($0, font: f) }
            let maxWidth = measured.map(\.width).max() ?? 0
            let lh = size * 1.36
            let boxHeight = CGFloat(rows.count) * lh + padding
            return (measured, maxWidth + padding * 2, boxHeight, lh)
        }

        var measurement = measure(fontSize)
        while (measurement.boxWidth > maxBoxWidth || measurement.boxHeight > maxBoxHeight), fontSize > minFontSize {
            fontSize -= 1
            measurement = measure(fontSize)
        }

        let boxWidth = measurement.boxWidth
        let boxHeight = measurement.boxHeight
        let lineHeight = measurement.lineHeight
        let boxOrigin = NSPoint(x: (bounds.width - boxWidth) / 2, y: headerHeight + (mazeAreaHeight - boxHeight) / 2)
        let backing = NSRect(origin: boxOrigin, size: NSSize(width: boxWidth, height: boxHeight))

        NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: backing, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(roundedRect: backing, xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()

        let f = font(fontSize)
        var y = boxOrigin.y + padding / 2
        for (rowWidth, parts) in measurement.rows {
            let rowStartX = boxOrigin.x + (boxWidth - rowWidth) / 2
            for part in parts {
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: part.color]
                (part.text as NSString).draw(at: NSPoint(x: rowStartX + part.x, y: y), withAttributes: attrs)
            }
            y += lineHeight
        }
    }

    private func drawPuffs(_ ctx: CGContext) {
        for p in puffs {
            let t = 1 - max(0, p.life / p.maxLife)
            let radius = cellSize * (0.15 + 0.35 * t)
            p.color.withAlphaComponent((1 - t) * 0.7).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p.position.x - radius, y: p.position.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = max(1, cellSize * 0.06)
            ring.stroke()
        }
    }

    private func drawConfetti(_ ctx: CGContext) {
        for p in particles {
            let t = max(0, p.life / p.maxLife)
            let radius = p.isSparkle ? cellSize * 0.07 * t + 0.5 : cellSize * 0.12 * t + 1
            let r = NSRect(x: p.position.x - radius, y: p.position.y - radius, width: radius * 2, height: radius * 2)

            if p.isSparkle {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: cellSize * 0.4, color: p.color.cgColor)
            }
            p.color.withAlphaComponent(t).setFill()
            NSBezierPath(ovalIn: r).fill()
            if p.isSparkle {
                ctx.restoreGState()
            }
        }
    }

    private func drawHeader() {
        let headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        headerColor.setFill()
        NSBezierPath(rect: headerRect).fill()

        theme(for: engine.mazeGeneration).wall.withAlphaComponent(0.3).setStroke()
        let separator = NSBezierPath()
        separator.lineWidth = 1
        separator.move(to: NSPoint(x: 0, y: headerHeight))
        separator.line(to: NSPoint(x: bounds.width, y: headerHeight))
        separator.stroke()

        let text = engine.generatorKind.displayName
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: theme(for: engine.mazeGeneration).wall
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(x: 14, y: (headerHeight - size.height) / 2)
        text.draw(at: point, withAttributes: attrs)
    }

    private func drawFooter() {
        let footerRect = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        headerColor.setFill()
        NSBezierPath(rect: footerRect).fill()

        theme(for: engine.mazeGeneration).wall.withAlphaComponent(0.3).setStroke()
        let separator = NSBezierPath()
        separator.lineWidth = 1
        separator.move(to: NSPoint(x: 0, y: footerRect.minY))
        separator.line(to: NSPoint(x: bounds.width, y: footerRect.minY))
        separator.stroke()

        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)

        if engine.isRace {
            let separatorText = " vs "
            let separatorColor = NSColor(calibratedWhite: 0.7, alpha: 0.8)
            let lineHeight = (separatorText as NSString).size(withAttributes: [.font: font]).height
            let y = footerRect.minY + (footerHeight - lineHeight) / 2
            var x: CGFloat = 14

            for (i, runner) in engine.runners.enumerated() {
                if i > 0 {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: separatorColor]
                    (separatorText as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    x += (separatorText as NSString).size(withAttributes: attrs).width
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accentColor(for: runner.kind)]
                let name = runner.kind.displayName
                (name as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                x += (name as NSString).size(withAttributes: attrs).width
            }
        } else {
            let text = engine.runners[0].kind.displayName
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accentColor(for: engine.runners[0].kind)]
            let size = text.size(withAttributes: attrs)
            let point = NSPoint(x: 14, y: footerRect.minY + (footerHeight - size.height) / 2)
            text.draw(at: point, withAttributes: attrs)
        }
    }
}

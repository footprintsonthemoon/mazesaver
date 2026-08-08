import Foundation

/// One "competitor" searching the same maze: its algorithm, its recorded search
/// (for the reveal animation), and its own progress through reveal/travel. Normal
/// mazes have exactly one runner; race mazes have two running side by side.
struct Runner {
    let kind: SearchAlgorithmKind
    let searchResult: SearchResult
    var revealAccumulator: Double = 0
    var revealedCount: Int = 0
    var pathProgress: Double = 0
    var finished: Bool = false
}

/// Drives the maze lifecycle: generate -> animate the search -> animate the ball(s)
/// travelling the solution path -> generate the next maze, using the old exit as
/// the new entrance so the journey feels continuous across mazes.
public final class MazeEngine {
    enum Phase: Equatable {
        /// Just the entrance point, pulsing quietly — before any maze structure
        /// is drawn at all. A calm beat marking "here's where it starts."
        case arriving
        /// The maze visibly carves itself into existence, replaying the exact
        /// sequence the generator used — a quick prelude before the search starts.
        case building
        /// A calm beat once construction is done and before the search begins —
        /// otherwise the build finishing and the search starting blur together.
        case builtPause
        case searching
        /// A brief, deliberate pause once the search is done and before the ball
        /// sets off — without it, search-done and travel-start blur together and
        /// it feels rushed.
        case settling
        case traveling
        /// The ball has reached the exit and rests there a moment before the maze
        /// dissolves into the next one — a beat to register "arrived" before it goes.
        case arrived
        /// The maze itself is gone — just the pulsing ball, sliding off the exit
        /// edge while its mirror image slides in from the opposite edge (matching
        /// the entrance/exit continuity), like it wrapped around to the next maze.
        case wrapping
    }

    let cols: Int
    let rows: Int

    private(set) var grid: MazeGrid
    private(set) var entrance: EdgeOpening
    private(set) var exit: EdgeOpening
    private(set) var generatorKind: MazeGeneratorKind
    private(set) var runners: [Runner]
    private(set) var phase: Phase = .arriving

    /// The exact wall-removal sequence the generator used for the current maze,
    /// and how far into it the "under construction" reveal has gotten.
    private(set) var carveSteps: [CarveStep]
    private(set) var builtCount = 0
    private var buildAccumulator: Double = 0
    private var pendingCarveSteps: [CarveStep]?

    /// Set to the index of whichever runner reaches the goal first in a race, so
    /// the view can show a "X wins" banner. Nil outside of races.
    private(set) var winnerRunnerIndex: Int?

    /// The algorithm that was running just before the current maze — captured at
    /// the moment of the swap so the view can fade the ball from that color into
    /// the new maze's algorithm color over the build animation, instead of
    /// snapping straight to it.
    private(set) var previousLeadKind: SearchAlgorithmKind?

    var leadRunnerIndex: Int {
        isRace ? (winnerRunnerIndex ?? 0) : 0
    }

    /// The next maze's structure, generated ahead of time so its entrance position
    /// is already known for the `.wrapping` ball animation to land on. Only non-nil
    /// during `.wrapping`.
    private(set) var pendingGrid: MazeGrid?
    private(set) var pendingEntrance: EdgeOpening?
    private(set) var pendingExit: EdgeOpening?
    private var pendingGeneratorKind: MazeGeneratorKind?
    private var pendingRunners: [Runner]?

    /// Bumped every time a new maze starts, so the view can reset per-maze visual
    /// state (confetti/puff tracking) without the engine knowing about them.
    private(set) var mazeGeneration = 0

    var isRace: Bool { runners.count > 1 }

    private var wrapTimer: Double = 0
    private var arrivingTimer: Double = 0
    private var builtPauseTimer: Double = 0
    private var settlingTimer: Double = 0
    private var arrivedTimer: Double = 0

    /// 0 at the start of the wrap animation, 1 once the ball has fully "arrived"
    /// on the opposite edge.
    var wrapProgress: Double {
        phase == .wrapping ? min(1, wrapTimer / wrapDuration) : 0
    }

    /// Seconds into `.wrapping`, for the view's brief old-maze fade-out — 0
    /// outside of that phase.
    var wrapElapsed: Double {
        phase == .wrapping ? wrapTimer : 0
    }

    /// Total length of `.wrapping`, so the view can carve its own fade/pause/slide
    /// sub-timeline out of it without duplicating the constant.
    var wrapTotalDuration: Double {
        wrapDuration
    }

    /// Seconds into the `.arriving` pulse, for the view to derive its ping
    /// animation from — 0 outside of that phase.
    var arrivingElapsed: Double {
        phase == .arriving ? arrivingTimer : 0
    }

    // Deliberately unhurried — this runs as a screensaver, not a race against the
    // clock, so it should read as calm and ambient rather than snappy.
    private let arrivingDuration: Double = 1.8
    private let baseCellsRevealedPerSecond: Double = 12
    private let maxRevealDuration: Double = 18
    /// Kept short and size-independent on purpose — this is a quick visual
    /// prelude, not something to linger on the way the search reveal does.
    private let baseBuildRevealPerSecond: Double = 60
    private let buildDuration: Double = 5
    /// Long enough for the exit marker's own 2s hidden delay plus its brief
    /// fade-in/pulse, plus a calm extra beat once it's visible and pulsing,
    /// before the search actually starts — see MazeView's
    /// exitAppearDelayDuration/exitFadeInDuration.
    private let builtPauseDuration: Double = 4
    private let settlingDuration: Double = 2
    private let arrivedDuration: Double = 5
    private let ballCellsPerSecond: Double = 7
    /// Races search slower than solo runs so the side-by-side comparison during the
    /// actual race (searching) is easy to follow. The final travel replay — done by
    /// just the winner once the race is decided — runs at the normal solo pace.
    private let raceSpeedMultiplier: Double = 0.55
    /// Slow and visible on purpose — this is the whole "one continuous corridor"
    /// illusion happening, not something to rush past. Long enough for the view's
    /// own fade-out + pause + slide choreography (see MazeView.drawWrapAnimation)
    /// to each get a comfortable, unhurried share of it.
    private let wrapDuration: Double = 4.5
    private let chaosProbability: Double = 0.1
    private let raceProbability: Double = 0.25
    /// However unlucky the dice are, force a race/chaos maze at least this often
    /// so it doesn't feel like the feature never shows up.
    private let maxMazesWithoutRace = 4
    private let maxMazesWithoutChaos = 6
    private var mazesSinceRace = 0
    private var mazesSinceChaos = 0

    /// Cycles through the "serious" algorithms in order (round-robin), starting at a
    /// random offset so successive app launches don't all begin with the same one.
    /// Chaos-mode mazes (random walk) don't consume a slot in this rotation.
    private var algorithmIndex = Int.random(in: 0..<SearchAlgorithmKind.roundRobinCases.count)
    /// Same idea for the maze generator, cycled independently of the search algorithm.
    private var generatorIndex = Int.random(in: 0..<MazeGeneratorKind.allCases.count)

    private func nextAlgorithmKind() -> SearchAlgorithmKind {
        let cases = SearchAlgorithmKind.roundRobinCases
        let kind = cases[algorithmIndex % cases.count]
        algorithmIndex += 1
        return kind
    }

    private func nextGeneratorKind() -> MazeGeneratorKind {
        let kind = MazeGeneratorKind.allCases[generatorIndex % MazeGeneratorKind.allCases.count]
        generatorIndex += 1
        return kind
    }

    /// Picks the race's second algorithm, retrying a few times to avoid an
    /// uninteresting race between two identical algorithms.
    private func pickRaceKinds() -> [SearchAlgorithmKind] {
        let first = nextAlgorithmKind()
        var second = nextAlgorithmKind()
        var guardCount = 0
        while second == first, guardCount < 8 {
            second = nextAlgorithmKind()
            guardCount += 1
        }
        return [first, second]
    }

    /// Decides what the next maze looks like: normally a single round-robin
    /// algorithm, rarely a capped random-walk "chaos" maze, occasionally a
    /// two-algorithm race — forced if it's been too long since the last one.
    private func pickAlgorithmKinds() -> [SearchAlgorithmKind] {
        let forceRace = mazesSinceRace >= maxMazesWithoutRace
        let forceChaos = !forceRace && mazesSinceChaos >= maxMazesWithoutChaos
        let roll = Double.random(in: 0..<1)
        let rollChaos = !forceRace && roll < chaosProbability

        if forceChaos || rollChaos {
            mazesSinceRace += 1
            mazesSinceChaos = 0
            return [.randomWalk]
        } else if forceRace || roll < chaosProbability + raceProbability {
            mazesSinceRace = 0
            mazesSinceChaos += 1
            return pickRaceKinds()
        } else {
            mazesSinceRace += 1
            mazesSinceChaos += 1
            return [nextAlgorithmKind()]
        }
    }

    private static func inwardFacing(for side: Side) -> Direction {
        switch side {
        case .west: return .east
        case .east: return .west
        case .north: return .south
        case .south: return .north
        }
    }

    private static func buildRunners(kinds: [SearchAlgorithmKind], grid: MazeGrid, start: GridPos, goal: GridPos, startFacing: Direction) -> [Runner] {
        kinds.map { kind in
            Runner(kind: kind, searchResult: Pathfinding.search(kind: kind, grid: grid, start: start, goal: goal, startFacing: startFacing))
        }
    }

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows

        // Inlined instead of calling nextGeneratorKind()/nextAlgorithmKind(): Swift
        // forbids instance method calls in init before every stored property is assigned.
        let generatorKind = MazeGeneratorKind.allCases[generatorIndex % MazeGeneratorKind.allCases.count]
        generatorIndex += 1
        self.generatorKind = generatorKind

        let startEntrance = EdgeOpening(side: .west, index: Int.random(in: 0..<rows))
        let (initialGrid, initialExit, initialCarveSteps) = MazeEngine.generateMaze(kind: generatorKind, cols: cols, rows: rows, entrance: startEntrance)
        self.grid = initialGrid
        self.entrance = startEntrance
        self.exit = initialExit
        self.carveSteps = initialCarveSteps

        // The very first maze is always a plain single-algorithm one; chaos/race
        // modes only kick in from the second maze onward (see startNextMaze).
        let roundRobinCases = SearchAlgorithmKind.roundRobinCases
        let algorithmKind = roundRobinCases[algorithmIndex % roundRobinCases.count]
        algorithmIndex += 1
        self.runners = [
            Runner(
                kind: algorithmKind,
                searchResult: Pathfinding.search(
                    kind: algorithmKind,
                    grid: initialGrid,
                    start: initialGrid.position(of: startEntrance),
                    goal: initialGrid.position(of: initialExit),
                    startFacing: MazeEngine.inwardFacing(for: startEntrance.side)
                )
            )
        ]
    }

    private static func generateMaze(kind: MazeGeneratorKind, cols: Int, rows: Int, entrance: EdgeOpening) -> (MazeGrid, EdgeOpening, [CarveStep]) {
        let grid = MazeGrid(cols: cols, rows: rows)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()
        let carveSteps = MazeGenerator.generate(kind: kind, grid: grid, start: grid.position(of: entrance), rng: &rng)

        let exitSide = Side.allCases.filter { $0 != entrance.side }.randomElement()!
        let exitIndex: Int
        switch exitSide {
        case .north, .south: exitIndex = Int.random(in: 0..<cols)
        case .east, .west: exitIndex = Int.random(in: 0..<rows)
        }
        let exit = EdgeOpening(side: exitSide, index: exitIndex)

        grid.openBorder(entrance)
        grid.openBorder(exit)
        return (grid, exit, carveSteps)
    }

    private func revealRate(forVisitedCount count: Int) -> Double {
        let rate = max(baseCellsRevealedPerSecond, Double(count) / maxRevealDuration)
        return isRace ? rate * raceSpeedMultiplier : rate
    }

    /// Advances the simulation by `dt` seconds.
    func tick(dt: Double) {
        switch phase {
        case .arriving:
            arrivingTimer += dt
            if arrivingTimer >= arrivingDuration {
                phase = .building
            }

        case .building:
            let rate = max(baseBuildRevealPerSecond, Double(carveSteps.count) / buildDuration)
            buildAccumulator += rate * dt
            builtCount = min(carveSteps.count, Int(buildAccumulator))
            if builtCount >= carveSteps.count {
                phase = .builtPause
                builtPauseTimer = 0
            }

        case .builtPause:
            builtPauseTimer += dt
            if builtPauseTimer >= builtPauseDuration {
                phase = .searching
            }

        case .searching:
            for i in runners.indices {
                let total = runners[i].searchResult.visitedOrder.count
                let wasComplete = runners[i].revealedCount >= total
                runners[i].revealAccumulator += revealRate(forVisitedCount: total) * dt
                runners[i].revealedCount = min(total, Int(runners[i].revealAccumulator))
                // The race is actually decided here: who finds the goal first.
                // (The solution path itself is identical for every algorithm, since
                // a perfect maze is a tree with exactly one route between any two
                // cells — so racing the replay afterwards wouldn't mean anything.)
                if !wasComplete, runners[i].revealedCount >= total, isRace, winnerRunnerIndex == nil {
                    winnerRunnerIndex = i
                }
            }
            if runners.allSatisfy({ $0.revealedCount >= $0.searchResult.visitedOrder.count }) {
                phase = .settling
                settlingTimer = 0
            }

        case .settling:
            settlingTimer += dt
            if settlingTimer >= settlingDuration {
                phase = .traveling
            }

        case .traveling:
            // Once a winner exists, only its ball keeps going, at the same pace as
            // a normal solo run — the loser's copy of the (identical) path is dropped.
            let leadIndex = isRace ? (winnerRunnerIndex ?? 0) : 0
            if !runners[leadIndex].finished {
                let maxProgress = Double(max(runners[leadIndex].searchResult.path.count - 1, 0))
                runners[leadIndex].pathProgress = min(maxProgress, runners[leadIndex].pathProgress + ballCellsPerSecond * dt)
                if runners[leadIndex].pathProgress >= maxProgress {
                    runners[leadIndex].finished = true
                }
            }
            if runners[leadIndex].finished {
                phase = .arrived
                arrivedTimer = 0
            }

        case .arrived:
            arrivedTimer += dt
            if arrivedTimer >= arrivedDuration {
                beginTransition()
            }

        case .wrapping:
            wrapTimer += dt
            if wrapTimer >= wrapDuration {
                commitPendingMaze()
            }
        }
    }

    /// Generates the next maze ahead of time (without touching the current, still
    /// visible one) and starts the crossfade.
    private func beginTransition() {
        let newEntrance = EdgeOpening(side: exit.side.opposite, index: exit.index)
        let newGeneratorKind = nextGeneratorKind()
        let (newGrid, newExit, newCarveSteps) = MazeEngine.generateMaze(kind: newGeneratorKind, cols: cols, rows: rows, entrance: newEntrance)

        let kinds = pickAlgorithmKinds()
        pendingRunners = MazeEngine.buildRunners(
            kinds: kinds,
            grid: newGrid,
            start: newGrid.position(of: newEntrance),
            goal: newGrid.position(of: newExit),
            startFacing: MazeEngine.inwardFacing(for: newEntrance.side)
        )
        pendingGrid = newGrid
        pendingGeneratorKind = newGeneratorKind
        pendingEntrance = newEntrance
        pendingExit = newExit
        pendingCarveSteps = newCarveSteps

        wrapTimer = 0
        phase = .wrapping
    }

    /// Swaps the pending maze into place once the wrap animation lands on it, and
    /// starts the arrival ping ahead of its build animation.
    private func commitPendingMaze() {
        guard let newGrid = pendingGrid, let newEntrance = pendingEntrance, let newExit = pendingExit,
              let newGeneratorKind = pendingGeneratorKind, let newRunners = pendingRunners,
              let newCarveSteps = pendingCarveSteps else { return }

        if runners.indices.contains(leadRunnerIndex) {
            previousLeadKind = runners[leadRunnerIndex].kind
        }

        grid = newGrid
        generatorKind = newGeneratorKind
        entrance = newEntrance
        exit = newExit
        runners = newRunners
        carveSteps = newCarveSteps
        builtCount = 0
        buildAccumulator = 0

        pendingGrid = nil
        pendingEntrance = nil
        pendingExit = nil
        pendingGeneratorKind = nil
        pendingRunners = nil
        pendingCarveSteps = nil

        winnerRunnerIndex = nil
        arrivingTimer = 0
        phase = .arriving
        mazeGeneration += 1
    }

    private func interpolatedPosition(along cells: [GridPos], progress: Double) -> (col: Double, row: Double) {
        guard !cells.isEmpty else {
            let p = grid.position(of: entrance)
            return (Double(p.col), Double(p.row))
        }
        let clamped = min(max(progress, 0), Double(cells.count - 1))
        let lower = Int(clamped)
        let upper = min(lower + 1, cells.count - 1)
        let t = clamped - Double(lower)
        let a = cells[lower]
        let b = cells[upper]
        let col = Double(a.col) + (Double(b.col) - Double(a.col)) * t
        let row = Double(a.row) + (Double(b.row) - Double(a.row)) * t
        return (col, row)
    }

    /// A runner's current grid-space position: it rides the search frontier while
    /// searching (so you can watch it "think"), then the solution path once it travels.
    func ballPosition(runnerIndex: Int) -> (col: Double, row: Double) {
        let runner = runners[runnerIndex]
        switch phase {
        case .arriving, .building, .builtPause, .searching, .settling:
            return interpolatedPosition(along: runner.searchResult.visitedOrder, progress: runner.revealAccumulator)
        case .traveling, .arrived, .wrapping:
            return interpolatedPosition(along: runner.searchResult.path, progress: runner.pathProgress)
        }
    }
}

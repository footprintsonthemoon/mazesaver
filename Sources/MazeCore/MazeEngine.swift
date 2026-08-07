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
        case searching
        /// A brief, deliberate pause once the search is done and before the ball
        /// sets off — without it, search-done and travel-start blur together and
        /// it feels rushed.
        case settling
        case traveling
        /// The ball has reached the exit and rests there a moment before the maze
        /// dissolves into the next one — a beat to register "arrived" before it goes.
        case arrived
        case betweenMazes
    }

    let cols: Int
    let rows: Int

    private(set) var grid: MazeGrid
    private(set) var entrance: EdgeOpening
    private(set) var exit: EdgeOpening
    private(set) var generatorKind: MazeGeneratorKind
    private(set) var runners: [Runner]
    private(set) var phase: Phase = .searching

    /// Set to the index of whichever runner reaches the goal first in a race, so
    /// the view can show a "X wins" banner. Nil outside of races.
    private(set) var winnerRunnerIndex: Int?

    /// The next maze's structure, generated ahead of time so it can be crossfaded
    /// in while the old maze (still held in `grid`/`entrance`/`exit`/`runners`)
    /// fades out, instead of a hard cut. Only non-nil during `.betweenMazes`.
    private(set) var pendingGrid: MazeGrid?
    private(set) var pendingEntrance: EdgeOpening?
    private(set) var pendingExit: EdgeOpening?
    private var pendingGeneratorKind: MazeGeneratorKind?
    private var pendingRunners: [Runner]?

    /// Bumped every time a new maze starts, so the view can reset per-maze visual
    /// state (confetti/puff tracking) without the engine knowing about them.
    private(set) var mazeGeneration = 0

    var isRace: Bool { runners.count > 1 }

    private var transitionTimer: Double = 0
    private var settlingTimer: Double = 0
    private var arrivedTimer: Double = 0

    /// 0 at the start of the crossfade, 1 once the new maze has fully faded in.
    var transitionProgress: Double {
        phase == .betweenMazes ? min(1, transitionTimer / transitionDuration) : 0
    }

    // Deliberately unhurried — this runs as a screensaver, not a race against the
    // clock, so it should read as calm and ambient rather than snappy.
    private let baseCellsRevealedPerSecond: Double = 12
    private let maxRevealDuration: Double = 18
    private let settlingDuration: Double = 2
    private let arrivedDuration: Double = 5
    private let ballCellsPerSecond: Double = 7
    /// Races search slower than solo runs so the side-by-side comparison during the
    /// actual race (searching) is easy to follow. The final travel replay — done by
    /// just the winner once the race is decided — runs at the normal solo pace.
    private let raceSpeedMultiplier: Double = 0.55
    private let transitionDuration: Double = 1.4
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
        let (initialGrid, initialExit) = MazeEngine.generateMaze(kind: generatorKind, cols: cols, rows: rows, entrance: startEntrance)
        self.grid = initialGrid
        self.entrance = startEntrance
        self.exit = initialExit

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

    private static func generateMaze(kind: MazeGeneratorKind, cols: Int, rows: Int, entrance: EdgeOpening) -> (MazeGrid, EdgeOpening) {
        let grid = MazeGrid(cols: cols, rows: rows)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()
        MazeGenerator.generate(kind: kind, grid: grid, start: grid.position(of: entrance), rng: &rng)

        let exitSide = Side.allCases.filter { $0 != entrance.side }.randomElement()!
        let exitIndex: Int
        switch exitSide {
        case .north, .south: exitIndex = Int.random(in: 0..<cols)
        case .east, .west: exitIndex = Int.random(in: 0..<rows)
        }
        let exit = EdgeOpening(side: exitSide, index: exitIndex)

        grid.openBorder(entrance)
        grid.openBorder(exit)
        return (grid, exit)
    }

    private func revealRate(forVisitedCount count: Int) -> Double {
        let rate = max(baseCellsRevealedPerSecond, Double(count) / maxRevealDuration)
        return isRace ? rate * raceSpeedMultiplier : rate
    }

    /// Advances the simulation by `dt` seconds.
    func tick(dt: Double) {
        switch phase {
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

        case .betweenMazes:
            transitionTimer += dt
            if transitionTimer >= transitionDuration {
                commitPendingMaze()
            }
        }
    }

    /// Generates the next maze ahead of time (without touching the current, still
    /// visible one) and starts the crossfade.
    private func beginTransition() {
        let newEntrance = EdgeOpening(side: exit.side.opposite, index: exit.index)
        let newGeneratorKind = nextGeneratorKind()
        let (newGrid, newExit) = MazeEngine.generateMaze(kind: newGeneratorKind, cols: cols, rows: rows, entrance: newEntrance)

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

        transitionTimer = 0
        phase = .betweenMazes
    }

    /// Swaps the faded-in pending maze into place and starts its search.
    private func commitPendingMaze() {
        guard let newGrid = pendingGrid, let newEntrance = pendingEntrance, let newExit = pendingExit,
              let newGeneratorKind = pendingGeneratorKind, let newRunners = pendingRunners else { return }

        grid = newGrid
        generatorKind = newGeneratorKind
        entrance = newEntrance
        exit = newExit
        runners = newRunners

        pendingGrid = nil
        pendingEntrance = nil
        pendingExit = nil
        pendingGeneratorKind = nil
        pendingRunners = nil

        winnerRunnerIndex = nil
        phase = .searching
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
        case .searching, .settling:
            return interpolatedPosition(along: runner.searchResult.visitedOrder, progress: runner.revealAccumulator)
        case .traveling, .arrived, .betweenMazes:
            return interpolatedPosition(along: runner.searchResult.path, progress: runner.pathProgress)
        }
    }
}

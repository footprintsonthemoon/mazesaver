import Foundation

enum MazeGeneratorKind: CaseIterable {
    case recursiveBacktracker
    case prim
    case wilson

    var displayName: String {
        switch self {
        case .recursiveBacktracker: return "Recursive Backtracker"
        case .prim: return "Prim"
        case .wilson: return "Wilson"
        }
    }
}

/// One wall removed during generation — the exact sequence of these is replayed
/// as the "maze under construction" animation, so each generator visibly builds
/// the way it actually works (backtracker as a single winding path, Prim as a
/// blob growing outward, Wilson in looping jumps).
struct CarveStep {
    let from: GridPos
    let direction: Direction
}

enum MazeGenerator {
    static func generate(kind: MazeGeneratorKind, grid: MazeGrid, start: GridPos, rng: inout RandomNumberGenerator) -> [CarveStep] {
        switch kind {
        case .recursiveBacktracker: return recursiveBacktracker(grid: grid, start: start, rng: &rng)
        case .prim: return prim(grid: grid, start: start, rng: &rng)
        case .wilson: return wilson(grid: grid, start: start, rng: &rng)
        }
    }

    /// Randomized depth-first search (recursive backtracker), carving a perfect maze
    /// (spanning tree over all cells: every cell reachable, no loops).
    static func recursiveBacktracker(grid: MazeGrid, start: GridPos, rng: inout RandomNumberGenerator) -> [CarveStep] {
        var steps: [CarveStep] = []
        var stack = [start]
        grid.setGenerated(start)

        while let current = stack.last {
            let unvisitedDirs = Direction.allCases.shuffled(using: &rng).filter { dir in
                guard let n = grid.neighbor(of: current, direction: dir) else { return false }
                return !grid.isGenerated(n)
            }

            guard let dir = unvisitedDirs.first else {
                stack.removeLast()
                continue
            }

            guard let next = grid.neighbor(of: current, direction: dir) else { continue }
            grid.removeWall(from: current, direction: dir)
            steps.append(CarveStep(from: current, direction: dir))
            grid.setGenerated(next)
            stack.append(next)
        }
        return steps
    }

    /// Randomized Prim's algorithm: grows the maze outward from `start` by repeatedly
    /// pulling in a random cell adjacent to the maze and carving a passage to it.
    /// Tends to produce more branching, shorter dead ends than the backtracker.
    static func prim(grid: MazeGrid, start: GridPos, rng: inout RandomNumberGenerator) -> [CarveStep] {
        var steps: [CarveStep] = []
        grid.setGenerated(start)
        var frontier: [GridPos] = []
        var inFrontier: Set<GridPos> = []

        func addFrontier(_ p: GridPos) {
            for dir in Direction.allCases {
                guard let n = grid.neighbor(of: p, direction: dir), !grid.isGenerated(n), !inFrontier.contains(n) else { continue }
                frontier.append(n)
                inFrontier.insert(n)
            }
        }

        addFrontier(start)

        while !frontier.isEmpty {
            let i = Int.random(in: 0..<frontier.count, using: &rng)
            let cell = frontier.remove(at: i)
            inFrontier.remove(cell)

            let dirsTowardMaze = Direction.allCases.filter { dir in
                guard let n = grid.neighbor(of: cell, direction: dir) else { return false }
                return grid.isGenerated(n)
            }
            guard let dir = dirsTowardMaze.randomElement(using: &rng) else { continue }

            grid.removeWall(from: cell, direction: dir)
            steps.append(CarveStep(from: cell, direction: dir))
            grid.setGenerated(cell)
            addFrontier(cell)
        }
        return steps
    }

    /// Wilson's algorithm: loop-erased random walks, producing a maze sampled
    /// uniformly at random among all perfect mazes on the grid (unlike the
    /// backtracker or Prim, which both have directional biases).
    static func wilson(grid: MazeGrid, start: GridPos, rng: inout RandomNumberGenerator) -> [CarveStep] {
        var steps: [CarveStep] = []
        grid.setGenerated(start)
        var inMaze = 1
        let total = grid.cols * grid.rows

        var order: [GridPos] = []
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                order.append(GridPos(col: col, row: row))
            }
        }
        order.shuffle(using: &rng)

        for candidate in order {
            guard !grid.isGenerated(candidate) else { continue }

            var path: [GridPos: Direction] = [:]
            var current = candidate
            while !grid.isGenerated(current) {
                let dir = Direction.allCases.randomElement(using: &rng)!
                guard let next = grid.neighbor(of: current, direction: dir) else { continue }
                path[current] = dir
                current = next
            }

            var cell = candidate
            while !grid.isGenerated(cell) {
                guard let dir = path[cell], let next = grid.neighbor(of: cell, direction: dir) else { break }
                grid.removeWall(from: cell, direction: dir)
                steps.append(CarveStep(from: cell, direction: dir))
                grid.setGenerated(cell)
                inMaze += 1
                cell = next
            }

            if inMaze >= total { break }
        }
        return steps
    }
}

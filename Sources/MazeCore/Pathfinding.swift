import Foundation

enum SearchAlgorithmKind: CaseIterable {
    case depthFirst
    case breadthFirst
    case aStar
    case wallFollower
    case randomWalk

    /// The kinds cycled through by the normal round-robin rotation. `randomWalk` is
    /// deliberately excluded — it has no step-count guarantee, so it only shows up
    /// as a rare, capped "chaos mode" surprise rather than in the regular rotation.
    static var roundRobinCases: [SearchAlgorithmKind] { [.depthFirst, .breadthFirst, .aStar, .wallFollower] }

    var displayName: String {
        switch self {
        case .depthFirst: return "Depth-First Search"
        case .breadthFirst: return "Breadth-First Search"
        case .aStar: return "A*"
        case .wallFollower: return "Wall Follower"
        case .randomWalk: return "Random Walk"
        }
    }

    /// Short tag shown next to a runner's ball, mainly to tell racers apart at a glance.
    var shortName: String {
        switch self {
        case .depthFirst: return "DFS"
        case .breadthFirst: return "BFS"
        case .aStar: return "A*"
        case .wallFollower: return "Wall"
        case .randomWalk: return "Random"
        }
    }
}

/// Result of running a search: the order cells were expanded in (for the reveal
/// animation) and the reconstructed solution path from start to goal.
struct SearchResult {
    let visitedOrder: [GridPos]
    let path: [GridPos]
}

enum Pathfinding {
    static func search(kind: SearchAlgorithmKind, grid: MazeGrid, start: GridPos, goal: GridPos, startFacing: Direction) -> SearchResult {
        switch kind {
        case .depthFirst: return depthFirstSearch(grid: grid, start: start, goal: goal)
        case .breadthFirst: return breadthFirstSearch(grid: grid, start: start, goal: goal)
        case .aStar: return aStarSearch(grid: grid, start: start, goal: goal)
        case .wallFollower: return wallFollower(grid: grid, start: start, goal: goal, startFacing: startFacing, rightHand: Bool.random())
        case .randomWalk: return randomWalk(grid: grid, start: start, goal: goal)
        }
    }

    private static func reconstructPath(parents: [GridPos: GridPos], start: GridPos, goal: GridPos) -> [GridPos] {
        var path = [goal]
        var current = goal
        while current != start, let p = parents[current] {
            path.append(p)
            current = p
        }
        return path.reversed()
    }

    static func depthFirstSearch(grid: MazeGrid, start: GridPos, goal: GridPos) -> SearchResult {
        var stack = [start]
        var visited: Set<GridPos> = [start]
        var order: [GridPos] = []
        var parents: [GridPos: GridPos] = [:]

        while let current = stack.popLast() {
            order.append(current)
            if current == goal {
                return SearchResult(visitedOrder: order, path: reconstructPath(parents: parents, start: start, goal: goal))
            }
            for next in grid.passableNeighbors(of: current) where !visited.contains(next) {
                visited.insert(next)
                parents[next] = current
                stack.append(next)
            }
        }
        return SearchResult(visitedOrder: order, path: [])
    }

    static func breadthFirstSearch(grid: MazeGrid, start: GridPos, goal: GridPos) -> SearchResult {
        var queue = [start]
        var head = 0
        var visited: Set<GridPos> = [start]
        var order: [GridPos] = []
        var parents: [GridPos: GridPos] = [:]

        while head < queue.count {
            let current = queue[head]; head += 1
            order.append(current)
            if current == goal {
                return SearchResult(visitedOrder: order, path: reconstructPath(parents: parents, start: start, goal: goal))
            }
            for next in grid.passableNeighbors(of: current) where !visited.contains(next) {
                visited.insert(next)
                parents[next] = current
                queue.append(next)
            }
        }
        return SearchResult(visitedOrder: order, path: [])
    }

    static func aStarSearch(grid: MazeGrid, start: GridPos, goal: GridPos) -> SearchResult {
        func heuristic(_ a: GridPos, _ b: GridPos) -> Int {
            abs(a.col - b.col) + abs(a.row - b.row)
        }

        var open = MinHeap<GridPos>()
        open.insert(start, priority: heuristic(start, goal))
        var gScore: [GridPos: Int] = [start: 0]
        var visited: Set<GridPos> = []
        var order: [GridPos] = []
        var parents: [GridPos: GridPos] = [:]

        while let current = open.popMin() {
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            order.append(current)

            if current == goal {
                return SearchResult(visitedOrder: order, path: reconstructPath(parents: parents, start: start, goal: goal))
            }

            let currentG = gScore[current] ?? 0
            for next in grid.passableNeighbors(of: current) {
                let tentativeG = currentG + 1
                if tentativeG < (gScore[next] ?? Int.max) {
                    gScore[next] = tentativeG
                    parents[next] = current
                    open.insert(next, priority: tentativeG + heuristic(next, goal))
                }
            }
        }
        return SearchResult(visitedOrder: order, path: [])
    }

    /// Hugs the right (or left) wall the whole way. Guaranteed to reach the goal
    /// because a perfect maze is simply connected (a spanning tree, no loops).
    static func wallFollower(grid: MazeGrid, start: GridPos, goal: GridPos, startFacing: Direction, rightHand: Bool) -> SearchResult {
        var current = start
        var facing = startFacing
        var order: [GridPos] = [start]
        var parents: [GridPos: GridPos] = [:]
        var firstVisited: Set<GridPos> = [start]

        // Bound on steps: a wall follower traverses each passage at most twice
        // (there and back) before reaching every corner of the spanning tree.
        let maxSteps = grid.cols * grid.rows * 4 + 16
        var steps = 0

        while current != goal, steps < maxSteps {
            steps += 1
            let candidates: [Direction] = rightHand
                ? [turnRight(facing), facing, turnLeft(facing), facing.opposite]
                : [turnLeft(facing), facing, turnRight(facing), facing.opposite]

            var moved = false
            for dir in candidates {
                guard !grid.hasWall(current, dir), let next = grid.neighbor(of: current, direction: dir) else { continue }
                if !firstVisited.contains(next) {
                    firstVisited.insert(next)
                    parents[next] = current
                }
                facing = dir
                current = next
                order.append(current)
                moved = true
                break
            }
            if !moved { break } // unreachable in a simply-connected maze, kept as a safety net
        }

        let path = current == goal ? reconstructPath(parents: parents, start: start, goal: goal) : []
        return SearchResult(visitedOrder: order, path: path)
    }

    /// Aimless "drunkard's walk": picks a random passable neighbor each step, with a
    /// mild bias against immediately reversing so it doesn't just jitter in place.
    /// Cover time on a maze graph can be very large in the worst case, so this is
    /// still capped as a safety net — but generously: the reveal *animation* speed
    /// is already time-bounded elsewhere (MazeEngine scales it to fit within
    /// maxRevealDuration regardless of step count), so there's no need for a tight
    /// step cap here. A tight cap just means the walk gets cut off before reaching
    /// the goal on larger screens/grids, and the travel replay then falls back to
    /// the BFS shortest path — a visibly different route from what was "explored",
    /// which looks like the search broke off partway through.
    static func randomWalk(grid: MazeGrid, start: GridPos, goal: GridPos) -> SearchResult {
        var current = start
        var previous: GridPos?
        var order: [GridPos] = [start]
        var parents: [GridPos: GridPos] = [:]
        var firstVisited: Set<GridPos> = [start]

        let maxSteps = min(grid.cols * grid.rows * 40, 200_000)
        var steps = 0

        while current != goal, steps < maxSteps {
            steps += 1
            var candidates = grid.passableNeighbors(of: current)
            if candidates.count > 1, let prev = previous {
                let withoutBacktrack = candidates.filter { $0 != prev }
                if !withoutBacktrack.isEmpty { candidates = withoutBacktrack }
            }
            guard let next = candidates.randomElement() else { break }

            if !firstVisited.contains(next) {
                firstVisited.insert(next)
                parents[next] = current
            }
            previous = current
            current = next
            order.append(current)
        }

        let path = current == goal
            ? reconstructPath(parents: parents, start: start, goal: goal)
            : breadthFirstSearch(grid: grid, start: start, goal: goal).path

        return SearchResult(visitedOrder: order, path: path)
    }

    private static func turnRight(_ d: Direction) -> Direction {
        switch d {
        case .north: return .east
        case .east: return .south
        case .south: return .west
        case .west: return .north
        }
    }

    private static func turnLeft(_ d: Direction) -> Direction {
        switch d {
        case .north: return .west
        case .west: return .south
        case .south: return .east
        case .east: return .north
        }
    }
}

/// Minimal binary min-heap priority queue, used by A*.
struct MinHeap<Element: Hashable> {
    private var items: [(element: Element, priority: Int)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func insert(_ element: Element, priority: Int) {
        items.append((element, priority))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].priority <= items[i].priority { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func popMin() -> Element? {
        guard !items.isEmpty else { return nil }
        let min = items[0]
        items[0] = items[items.count - 1]
        items.removeLast()
        var i = 0
        while true {
            let left = 2 * i + 1, right = 2 * i + 2
            var smallest = i
            if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
            if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
            if smallest == i { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return min.element
    }
}

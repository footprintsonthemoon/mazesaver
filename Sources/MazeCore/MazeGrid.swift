import Foundation

enum Side: CaseIterable {
    case north, south, east, west

    var opposite: Side {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }
}

enum Direction: CaseIterable {
    case north, south, east, west

    var opposite: Direction {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }

    var delta: (dx: Int, dy: Int) {
        switch self {
        case .north: return (0, -1)
        case .south: return (0, 1)
        case .east: return (1, 0)
        case .west: return (-1, 0)
        }
    }
}

struct GridPos: Hashable {
    var col: Int
    var row: Int
}

struct Cell {
    var walls: Set<Direction> = Set(Direction.allCases)
    var generated = false
}

/// Marks a border opening: which grid cell is opened to the outside, on which side.
struct EdgeOpening {
    var side: Side
    var index: Int // row index for east/west, column index for north/south
}

final class MazeGrid {
    let cols: Int
    let rows: Int
    private(set) var cells: [Cell]

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.cells = Array(repeating: Cell(), count: cols * rows)
    }

    private func index(_ p: GridPos) -> Int { p.row * cols + p.col }

    func inBounds(_ p: GridPos) -> Bool {
        p.col >= 0 && p.col < cols && p.row >= 0 && p.row < rows
    }

    func cell(_ p: GridPos) -> Cell { cells[index(p)] }

    func neighbor(of p: GridPos, direction: Direction) -> GridPos? {
        let d = direction.delta
        let n = GridPos(col: p.col + d.dx, row: p.row + d.dy)
        return inBounds(n) ? n : nil
    }

    func removeWall(from a: GridPos, direction: Direction) {
        cells[index(a)].walls.remove(direction)
        if let b = neighbor(of: a, direction: direction) {
            cells[index(b)].walls.remove(direction.opposite)
        }
    }

    func hasWall(_ p: GridPos, _ direction: Direction) -> Bool {
        cells[index(p)].walls.contains(direction)
    }

    func setGenerated(_ p: GridPos) {
        cells[index(p)].generated = true
    }

    func isGenerated(_ p: GridPos) -> Bool {
        cells[index(p)].generated
    }

    /// Cells reachable from `p` through open passages (no wall between them).
    func passableNeighbors(of p: GridPos) -> [GridPos] {
        Direction.allCases.compactMap { dir in
            guard !hasWall(p, dir) else { return nil }
            return neighbor(of: p, direction: dir)
        }
    }

    func position(of opening: EdgeOpening) -> GridPos {
        switch opening.side {
        case .west: return GridPos(col: 0, row: opening.index)
        case .east: return GridPos(col: cols - 1, row: opening.index)
        case .north: return GridPos(col: opening.index, row: 0)
        case .south: return GridPos(col: opening.index, row: rows - 1)
        }
    }

    /// Removes the outward-facing wall for a border opening, so it looks connected to the screen edge.
    func openBorder(_ opening: EdgeOpening) {
        let p = position(of: opening)
        let outward: Direction
        switch opening.side {
        case .west: outward = .west
        case .east: outward = .east
        case .north: outward = .north
        case .south: outward = .south
        }
        cells[index(p)].walls.remove(outward)
    }
}

import Foundation

/// One card on screen: the same title can stand in several rows.
public struct CardID: Hashable, Sendable, CustomStringConvertible {
    public var row: String
    public var ref: TitleRef

    public init(row: String, ref: TitleRef) {
        self.row = row
        self.ref = ref
    }

    public var description: String { "\(row)|\(ref)" }
}

/// A line of cards as the keyboard sees it: a horizontal row, or one line
/// of a grid. `width` is a card's width plus spacing, to find the card
/// below another one in a row of a different card size.
public struct CardLine: Sendable, Equatable {
    public var key: String
    public var row: String
    public var cards: [TitleRef]
    public var width: Double

    public init(key: String, row: String, cards: [TitleRef], width: Double) {
        self.key = key
        self.row = row
        self.cards = cards
        self.width = width
    }
}

public enum Move: Sendable {
    case left, right, up, down, home, end
}

/// The arrow keys over rows of cards, like the design: left and right stay
/// in a row, up and down go to the card the row last had, else the one
/// nearest below or above.
public struct CardNavigator: Sendable {
    public var lines: [CardLine]
    /// The last column per line.
    public var remembered: [String: Int] = [:]
    /// Where each card is, so a move over thousands of cards is a lookup.
    private var places: [CardID: (line: Int, column: Int)] = [:]

    public init(lines: [CardLine] = []) {
        self.lines = lines
        for (l, line) in lines.enumerated() {
            for (c, ref) in line.cards.enumerated() {
                let id = CardID(row: line.row, ref: ref)
                if places[id] == nil { places[id] = (l, c) }
            }
        }
    }

    public func position(of card: CardID) -> (line: Int, column: Int)? {
        places[card]
    }

    public func card(line: Int, column: Int) -> CardID? {
        guard lines.indices.contains(line), lines[line].cards.indices.contains(column) else { return nil }
        return CardID(row: lines[line].row, ref: lines[line].cards[column])
    }

    public var first: CardID? { card(line: 0, column: remembered[lines.first?.key ?? ""] ?? 0) ?? card(line: 0, column: 0) }

    public mutating func move(_ move: Move, from card: CardID?) -> CardID? {
        guard let card, let (l, c) = position(of: card) else { return first }
        let line = lines[l]
        var target: (Int, Int)?
        switch move {
        case .left: target = c > 0 ? (l, c - 1) : nil
        case .right: target = c + 1 < line.cards.count ? (l, c + 1) : nil
        case .home: target = (l, 0)
        case .end: target = (l, line.cards.count - 1)
        case .up, .down:
            let next = move == .down ? l + 1 : l - 1
            if lines.indices.contains(next) {
                let other = lines[next]
                let nearest = Int((Double(c) * line.width / other.width).rounded())
                let column = remembered[other.key] ?? nearest
                target = (next, min(max(column, 0), other.cards.count - 1))
            }
        }
        guard let (tl, tc) = target, let found = self.card(line: tl, column: tc) else { return nil }
        remembered[lines[tl].key] = tc
        return found
    }

    /// After a reload: the same card if it is still there, else the card now
    /// at its place in the same row, else the first card.
    public func keep(_ card: CardID?, previous: CardNavigator) -> CardID? {
        guard let card else { return nil }
        if position(of: card) != nil { return card }
        if let (l, c) = previous.position(of: card) {
            let row = previous.lines[l].row
            let flat = lines.filter { $0.row == row }.flatMap(\.cards)
            if !flat.isEmpty { return CardID(row: row, ref: flat[min(c, flat.count - 1)]) }
        }
        return first
    }

    /// Splits a grid into lines of `columns` cards.
    public static func gridLines(row: String, cards: [TitleRef], columns: Int, width: Double) -> [CardLine] {
        let columns = max(columns, 1)
        return stride(from: 0, to: cards.count, by: columns).map { start in
            CardLine(
                key: "\(row)#\(start / columns)", row: row, cards: Array(cards[start..<min(start + columns, cards.count)]),
                width: width)
        }
    }
}

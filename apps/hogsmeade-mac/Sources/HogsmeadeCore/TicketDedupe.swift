import Foundation

/// One ticket often arrives twice: as a PDF and as a Wallet pass with the same
/// code. Passes win; otherwise the first card with a code stays. Cards whose
/// code is unknown always stay.
public enum TicketDedupe {
    public struct Item: Sendable {
        public var payload: String?
        public var isPass: Bool

        public init(payload: String?, isPass: Bool) {
            self.payload = payload
            self.isPass = isPass
        }
    }

    public static func keep(_ items: [Item]) -> [Bool] {
        let passes = Set(items.filter(\.isPass).compactMap(\.payload))
        var seen = Set<String>()
        return items.map { item in
            guard let payload = item.payload, !payload.isEmpty else { return true }
            if !item.isPass, passes.contains(payload) { return false }
            return seen.insert(payload).inserted
        }
    }
}

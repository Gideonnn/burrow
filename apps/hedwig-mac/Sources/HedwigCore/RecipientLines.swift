import Foundation

public struct RecipientNames: Equatable, Sendable {
    public var shown: String
    public var more: Int
}

/// One "Aan:", "Kopie:" or "Antwoord aan:" line in the reader's header.
public struct RecipientLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case to, cc, replyTo }

    public let kind: Kind
    public let addresses: [Address]

    public init(kind: Kind, addresses: [Address]) {
        self.kind = kind
        self.addresses = addresses
    }

    public var id: Kind { kind }

    public var label: String {
        switch kind {
        case .to: "Aan"
        case .cc: "Kopie"
        case .replyTo: "Antwoord aan"
        }
    }

    // A "+1" would hide no more than the name it replaces, so the limit only
    // bites from two hidden names on.
    public func names(limit: Int?) -> RecipientNames {
        let all = addresses.map(Self.name)
        guard let limit, all.count > limit + 1 else {
            return RecipientNames(shown: all.joined(separator: ", "), more: 0)
        }
        return RecipientNames(shown: all.prefix(limit).joined(separator: ", "), more: all.count - limit)
    }

    public var tooltip: String {
        addresses.map { address in
            let name = Self.name(address)
            return name == address.email ? address.email : "\(name) <\(address.email)>"
        }.joined(separator: "\n")
    }

    private static func name(_ address: Address) -> String {
        let name = address.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? address.email : name
    }
}

public enum RecipientLines {
    public static func lines(from: Address, to: [Address], cc: [Address], replyTo: [Address]) -> [RecipientLine] {
        var lines = [RecipientLine(kind: .to, addresses: to)]
        if !cc.isEmpty { lines.append(RecipientLine(kind: .cc, addresses: cc)) }
        let sender = Set([from.email.lowercased()])
        if !replyTo.isEmpty, Set(replyTo.map { $0.email.lowercased() }) != sender {
            lines.append(RecipientLine(kind: .replyTo, addresses: replyTo))
        }
        return lines
    }
}

extension MessageDetail {
    public var recipientLines: [RecipientLine] {
        RecipientLines.lines(from: from, to: to, cc: cc, replyTo: replyTo ?? [])
    }
}

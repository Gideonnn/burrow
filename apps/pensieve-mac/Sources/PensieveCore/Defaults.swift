import Foundation

/// What a one-click recording is called before anyone types: the title and
/// labels of the person's previous recording of that kind. The calendar will
/// come first once Burrow has the calendars.
public enum RecordingDefaults {
    public static func name(of kind: RecordingKind) -> String {
        switch kind {
        case .call: "Gesprek"
        case .video: "Video"
        case .screen: "Scherm"
        case .dictation: "Dictaat"
        }
    }

    public static func suggestion(for kind: RecordingKind, after recordings: [RecordingSummary]) -> (title: String, labels: [String]) {
        let previous = recordings.filter { $0.mine && $0.kind == kind }.max { $0.startedAt < $1.startedAt }
        // A dictation's title is its first words, so it is never carried over.
        let title = kind == .dictation ? name(of: kind) : previous?.title ?? name(of: kind)
        return (title, previous?.labels ?? [])
    }
}

/// Marks made while recording: seconds from the start, in order.
public struct MarkList: Sendable, Equatable {
    public private(set) var marks: [Mark] = []

    public init(_ marks: [Mark] = []) { self.marks = marks.sorted { $0.at < $1.at } }

    /// Marks now; a second press within a second is the same moment.
    @discardableResult
    public mutating func mark(at seconds: Double, note: String? = nil) -> Int {
        if let last = marks.indices.last, abs(marks[last].at - seconds) < 1 {
            if let note { marks[last].note = note }
            return last
        }
        marks.append(Mark(at: max(0, seconds), note: note))
        marks.sort { $0.at < $1.at }
        return marks.firstIndex { $0.at == max(0, seconds) } ?? marks.count - 1
    }

    public mutating func setNote(_ note: String?, at index: Int) {
        guard marks.indices.contains(index) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        marks[index].note = trimmed?.isEmpty == false ? trimmed : nil
    }

    public mutating func remove(at index: Int) {
        guard marks.indices.contains(index) else { return }
        marks.remove(at: index)
    }
}

import LumosCore
import SwiftUI

/// Which seasons of a series go on the list, and so to Seerr: the first by
/// default, all of them, or a hand-picked set. Nothing is asked before "Ja".
public struct SeasonMenu<Label: View>: View {
    let total: Int
    @Binding var selection: Set<Int>
    let label: Label

    public init(total: Int, selection: Binding<Set<Int>>, @ViewBuilder label: () -> Label) {
        self.total = total
        _selection = selection
        self.label = label()
    }

    public var body: some View {
        Menu {
            Button("Alle seizoenen") { selection = Set(1...total) }
            Button("Alleen seizoen 1") { selection = [1] }
            Divider()
            ForEach(1...total, id: \.self) { season in
                Toggle("Seizoen \(season)", isOn: Binding(
                    get: { selection.contains(season) },
                    set: { on in
                        if on { selection.insert(season) } else if selection.count > 1 { selection.remove(season) }
                    }))
            }
        } label: {
            label
        }
        .help("Welke seizoenen op de lijst komen en aangevraagd worden; J neemt seizoen 1")
    }

    /// "Seizoen 1", "Alle seizoenen" or "Seizoen 1, 3".
    public static func text(_ selection: Set<Int>, total: Int) -> String {
        let label = LumosModel.seasonsLabel(Array(selection), of: total)
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

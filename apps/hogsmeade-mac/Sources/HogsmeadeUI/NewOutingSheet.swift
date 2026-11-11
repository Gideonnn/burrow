import HogsmeadeCore
import SwiftUI

/// Nieuw uitje: what, when and where.
public struct NewOutingSheet: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = ""
    @State private var startsAt = NewOutingSheet.nextEvening()
    @State private var venue = ""
    @State private var saving = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nieuw uitje").font(.title2.weight(.semibold))
            Text("Meestal hoeft dit niet: Hedwig ziet de bevestigingsmail en hangt het uitje vanzelf aan de wand. Alleen voor iets zonder mail.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Wat", text: $title, prompt: Text("Bijvoorbeeld Schaatsen op de Jaap Eden"))
                TextField("Soort", text: $kind, prompt: Text("concert, theater, feest…"))
                DatePicker("Wanneer", selection: $startsAt)
                TextField("Waar", text: $venue, prompt: Text("Zaal of adres"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Laat maar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hang aan de wand") {
                    saving = true
                    Task {
                        await model.create(title: title, startsAt: startsAt, venue: venue, kind: kind)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    /// Tomorrow at eight.
    public static func nextEvening(now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

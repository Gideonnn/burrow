import HedwigCore
import SwiftUI

/// Above the list while a mailbox's login was refused: sync waits, and changes
/// such as marking as read fail until the person logs in again.
struct ReconnectNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let mailbox: MailboxSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("De koppeling met \(mailbox.address) is verlopen").font(.callout.weight(.semibold))
                Text("Nieuwe mail komt niet binnen en gelezen markeren lukt niet tot je opnieuw inlogt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Opnieuw inloggen") {
                Task {
                    if let url = await model.reconnectLink(mailbox) { openURL(url) }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

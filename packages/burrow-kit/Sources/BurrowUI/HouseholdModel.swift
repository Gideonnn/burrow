import BurrowKit
import Foundation
import Observation

/// The shared settings screens' state: what modules offer, the person's own
/// values, and for admins everyone in the household with their devices.
@MainActor
@Observable
public final class HouseholdModel {
    public private(set) var schema: [SettingDefinition] = []
    public private(set) var mine: [String: SettingValue] = [:]
    public private(set) var members: [HouseholdMember] = []
    public private(set) var catalog: Catalog?
    public private(set) var tasks: [TaskItem] = []
    public private(set) var isAdmin = false
    public var error: String?
    @ObservationIgnored private let api: @MainActor () -> APIClient?
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(api: @escaping @MainActor () -> APIClient?) { self.api = api }

    deinit { following?.cancel() }

    /// Loads everything, and from then on follows the server: a setting
    /// changed on another Mac, a new person or key, shows here at once.
    public func load() async {
        guard let api = api() else { return }
        if following == nil {
            following = Task { [weak self] in
                guard let stream = self?.api()?.events() else { return }
                for await event in stream where ["settings.changed", "household.changed", "task.changed"].contains(event.type) {
                    if event.type == "task.changed" { await self?.refreshTasks() } else { await self?.load() }
                }
            }
        }
        do {
            let profile = try await api.profile()
            myPersonId = profile.person.id
            isAdmin = profile.isAdmin
            schema = try await api.settingsSchema()
            mine = try await api.settings()
            members = isAdmin ? try await api.household() : []
            catalog = try? await api.catalog()
            tasks = (try? await api.tasks()) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func refreshTasks() async {
        guard let api = api() else { return }
        tasks = (try? await api.tasks()) ?? tasks
    }

    /// Changes a setting for `personId`, or for the person behind the key.
    public func set(_ key: String, _ value: SettingValue, for personId: String? = nil) async {
        guard let api = api() else { return }
        do {
            if let personId, members.first(where: { $0.id == personId }) != nil, !isMine(personId) {
                let values = try await api.updateSettings(of: personId, [key: value])
                if let index = members.firstIndex(where: { $0.id == personId }) { members[index].settings = values }
            } else {
                mine = try await api.updateSettings([key: value])
                if let index = members.firstIndex(where: { isMine($0.id) }) { members[index].settings = mine }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func revoke(_ key: ApiKeySummary) async {
        guard let api = api() else { return }
        do {
            try await api.revokeKey(key.id)
            members = try await api.household()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func retry(_ task: TaskItem) async {
        guard let api = api() else { return }
        try? await api.retry(task: task.id)
        await refreshTasks()
    }

    public private(set) var myPersonId: String?

    func isMine(_ personId: String) -> Bool { personId == myPersonId }

    public func values(for personId: String) -> [String: SettingValue] {
        members.first { $0.id == personId }?.settings ?? mine
    }
}

import BurrowKit
import Foundation

extension AppModel {
    public func refreshTasks() async {
        guard let api else { return }
        await refreshRunners()
        if let list = try? await api.tasks() {
            tasks = list
            if selectedTaskId == nil || !list.contains(where: { $0.id == selectedTaskId }) {
                selectedTaskId = list.first(where: { $0.status == "review" })?.id ?? list.first?.id
            }
        }
    }

    public func approve(_ task: TaskItem) async {
        guard let api else { return }
        do {
            try await api.approve(task: task.id)
            await refreshTasks()
            await refreshDrafts()
        } catch {
            report(error)
        }
    }

    public func reject(_ task: TaskItem) async {
        guard let api else { return }
        do {
            try await api.reject(task: task.id)
            await refreshTasks()
        } catch {
            report(error)
        }
    }

    public var tasksAwaitingReview: Int { tasks.filter { $0.status == "review" }.count }

    public func refreshRunners() async {
        guard let api, me?.can(.read) == true else { return }
        runners = try? await api.runners()
    }

    /// The runners this person registered from this Mac (`burrowctl runner`).
    public var thisMacRunners: [RunnerInfo] {
        let name = RunnerConfig.load().name
        return runners?.runners.filter { $0.mine && $0.name == name } ?? []
    }

    /// What this Mac's runner is doing, for the task list.
    public var runnerStatus: String {
        guard let mine = thisMacRunners.first else { return "Geen runner op deze Mac" }
        if !mine.online { return "Runner offline" }
        if mine.paused { return "Runner gepauzeerd" }
        return mine.doing ?? "Runner wacht op taken"
    }

    public func setRunner(_ runner: RunnerInfo, paused: Bool) async {
        guard let api else { return }
        do {
            try await api.setRunner(id: runner.id, paused: paused)
            await refreshRunners()
        } catch {
            report(error)
        }
    }
}

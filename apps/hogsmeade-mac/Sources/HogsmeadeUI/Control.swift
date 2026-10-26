import BurrowKit
import BurrowUI
import Foundation
import HogsmeadeCore

/// What `burrowctl hogsmeade state` answers.
@MainActor
public func controlState(_ model: OutingsModel) -> [String: Any] {
    var state: [String: Any] = [
        "connected": model.connection?.serverURL.host() ?? NSNull(),
        "serverReachable": model.reachability.isReachable,
        "page": model.page.rawValue,
        "query": model.query,
        "today": model.today?.title ?? NSNull(),
        "upcoming": model.upcoming.prefix(20).map { "\($0.title) (\($0.id)) \(model.nightsLabel($0)) · \($0.status(now: model.now()).text)" },
        "past": model.past.prefix(10).map { "\($0.title) (\($0.id))" },
    ]
    if let open = model.open {
        state["open"] = [
            "id": open.id, "title": open.title, "when": OutingFormat.when(open, now: model.now()),
            "where": OutingFormat.whereLines(open).joined(separator: ", "),
            "who": open.attendees.map(\.name), "tickets": open.tickets.count,
            "todo": open.openItems().map(\.task.title), "stamp": open.wallStamp().text,
        ] as [String: Any]
    }
    if let toast = model.toast { state["toast"] = toast.message }
    if let error = model.error { state["error"] = error }
    return state
}

/// Hogsmeade's commands for agents: look around, search and open an outing.
@MainActor
public func registerCommands(_ service: ControlService, model: OutingsModel) {
    service.register("show", help: "Show a page: upcoming, past, wall (the posters even on the night itself) or tonight.", arguments: [.init("page", "upcoming, past, wall or tonight")]) { request in
        let name = request["page"] as? String ?? "upcoming"
        guard let page = OutingsModel.Page(rawValue: name) ?? (name == "wall" || name == "tonight" ? .upcoming : nil) else {
            throw ControlError("page is upcoming, past, wall or tonight")
        }
        model.page = page
        model.tonightHidden = name == "wall"
        model.close()
        return controlState(model)
    }
    service.register("search", help: "Search outings by title, kind, place or organiser.", arguments: [.init("query", "the words")]) { request in
        model.query = request["query"] as? String ?? ""
        return controlState(model)
    }
    service.register("open", help: "Open an outing's page by id.", arguments: [.init("id", "the outing's id")]) { request in
        guard let id = request["id"] as? String, model.outings.contains(where: { $0.id == id }) else {
            throw ControlError("no outing with that id; see `state`")
        }
        model.open(id)
        return controlState(model)
    }
    service.register("close", help: "Close the open outing.") { _ in
        model.close()
        return controlState(model)
    }
}

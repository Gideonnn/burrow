import BurrowKit
import BurrowUI
import Foundation
import LumosCore

/// What `burrowctl lumos state` answers.
@MainActor
public func controlState(_ model: LumosModel) -> [String: Any] {
    var state: [String: Any] = [
        "connected": model.connection?.serverURL.host() ?? NSNull(),
        "serverReachable": model.reachability.isReachable,
        "dataOrigin": model.status?.dataOrigin?.rawValue ?? NSNull(),
        "page": model.page.rawValue,
        "scope": model.scope.rawValue,
        "query": model.query,
        "mood": model.mood.rawValue,
        "rows": model.rows.map { row in
            [
                "key": row.key, "title": row.title,
                "items": row.items.prefix(20).map { "\($0.title) (\($0.ref))\($0.onList ? " ✓" : "")" },
            ] as [String: Any]
        },
        "cursor": model.cursor?.description ?? NSNull(),
        "focus": "\(model.focus)",
        "canUndo": model.canUndo,
    ]
    if let detail = model.detail {
        state["open"] = [
            "ref": detail.ref.description, "title": detail.title, "onList": detail.onList,
            "pass": detail.pass.map { "\($0.kind.rawValue) \($0.reason ?? "")" } ?? NSNull(),
            "trailer": detail.trailer?.publisher ?? NSNull(),
            "scores": detail.scores.map { "\($0.source) \($0.label ?? "") \($0.valueText)" },
        ] as [String: Any]
    }
    if let player = model.player { state["player"] = player.statusText }
    if let toast = model.toast { state["toast"] = toast.message }
    if let error = model.error { state["error"] = error }
    return state
}

/// Lumos's own commands for agents: look around, search and open a title.
/// Putting a title on a list is the person's (it will request media later).
@MainActor
public func registerCommands(_ service: ControlService, model: LumosModel) {
    service.register(
        "show", help: "Show a page: discover, list, movies, series, available, taste or passed; optionally for shared or mine.",
        arguments: [.init("page", "discover, list, movies, series, available, taste or passed"), .init("scope", "shared or mine")]
    ) { request in
        guard let page = LumosModel.Page(rawValue: request["page"] as? String ?? "discover"), page != .search else {
            throw ControlError("page is discover, list, movies, series, available, taste or passed")
        }
        if let text = request["scope"] as? String {
            guard let scope = ListScope(rawValue: text) else { throw ControlError("scope is shared or mine") }
            model.scope = scope
        }
        await model.show(page)
        return controlState(model)
    }
    service.register("search", help: "Search titles by title, maker, cast, genre or trait.", arguments: [.init("query", "the words")]) { request in
        model.query = request["query"] as? String ?? ""
        try? await Task.sleep(for: .milliseconds(400))
        return controlState(model)
    }
    service.register(
        "open", help: "Open a title's details, e.g. movie:9000001.", arguments: [.init("ref", "mediaType:tmdbId")]
    ) { request in
        guard let ref = TitleRef(request["ref"] as? String ?? "") else { throw ControlError("ref is like movie:9000001") }
        model.open(ref, focusInside: true)
        await model.detailTaskForTests?.value
        return controlState(model)
    }
    service.register("trailer", help: "Play the open title's trailer in the inspector; it streams, nothing is kept.") { _ in
        await model.playTrailer()
        return controlState(model)
    }
    service.register("stop", help: "Stop the trailer.") { _ in
        model.stopTrailer()
        return controlState(model)
    }
    service.register("close", help: "Close the details.") { _ in
        model.closeInspector()
        return controlState(model)
    }
}

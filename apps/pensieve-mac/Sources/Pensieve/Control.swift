import BurrowKit
import BurrowUI
import Foundation
import PensieveCore

/// What `burrowctl pensieve state` answers.
@MainActor
func controlState(_ model: PensieveModel, _ recorder: RecorderController) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    var state: [String: Any] = [
        "connected": model.connection?.serverURL.host() ?? NSNull(),
        "serverReachable": model.reachability.isReachable,
        "scope": model.scope.rawValue,
        "query": model.query,
        "kind": model.kindFilter?.rawValue ?? NSNull(),
        "labelFilter": model.labelFilter.sorted(),
        "labels": model.labels.map { ["name": $0.name, "count": $0.count] as [String: Any] },
        "recordings": model.recordings.prefix(50).map { r in
            [
                "id": r.id, "kind": r.kind.rawValue, "title": r.title, "labels": r.labels, "owner": r.owner.name, "mine": r.mine,
                "sharedWith": r.sharedWith.map(\.name), "startedAt": iso.string(from: r.startedAt),
                "minutes": Int((r.durationSeconds ?? 0) / 60), "status": r.status.rawValue,
                "preview": r.preview ?? "",
            ] as [String: Any]
        },
        "selectedId": model.selectedId ?? NSNull(),
        "waitingForUpload": model.pending.map(\.title),
        "recording": recorder.isRecording
            ? [
                "kind": recorder.kind.rawValue, "title": recorder.title, "minutes": Int(recorder.elapsed / 60),
                "labels": recorder.labels, "marks": recorder.marks.marks.map { stamp($0.at) },
            ] as [String: Any] : NSNull(),
    ]
    if let detail = model.detail {
        state["open"] = [
            "id": detail.id, "kind": detail.kind.rawValue, "title": detail.title, "status": detail.status.rawValue,
            "labels": detail.labels, "marks": detail.marks.map { "\(stamp($0.at)) \($0.note ?? "")".trimmingCharacters(in: .whitespaces) },
            "notes": detail.notesMarkdown ?? "", "transcriptWords": detail.transcript?.split(separator: " ").count ?? 0,
        ] as [String: Any]
    }
    if let error = model.error { state["error"] = error }
    return state
}

/// Pensieve's own commands for agents. Starting a recording is the person's:
/// an agent can mark or stop one, but never start one. Sharing asks the person.
@MainActor
func registerCommands(_ service: ControlService, model: PensieveModel, recorder: RecorderController) {
    service.register(
        "show", help: "Show all recordings, only your own, or those shared with you; optionally one kind and any of some labels.",
        arguments: [
            .init("scope", "all, mine or shared"), .init("kind", "call, video, screen, dictation or all"),
            .init("labels", "label names separated by commas; empty for any"),
        ]
    ) { request in
        guard let scope = RecordingScope(rawValue: request["scope"] as? String ?? "all") else {
            throw ControlError("scope is all, mine or shared")
        }
        let kindText = request["kind"] as? String ?? "all"
        guard kindText == "all" || RecordingKind(rawValue: kindText) != nil else {
            throw ControlError("kind is call, video, screen, dictation or all")
        }
        model.scope = scope
        model.kindFilter = RecordingKind(rawValue: kindText)
        model.labelFilter = Set(
            (request["labels"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        await model.reload()
        return controlState(model, recorder)
    }
    service.register(
        "label", help: "Set your labels on a recording you can see, replacing the ones it had.",
        arguments: [.init("id", "a recording id"), .init("labels", "label names separated by commas")]
    ) { request in
        let labels = (request["labels"] as? String ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await model.setLabels(request["id"] as? String ?? "", labels)
        return controlState(model, recorder)
    }
    service.register("transcribe", help: "Make the transcript of a stored video or screen recording; only its sound goes to the server.", arguments: [.init("id", "a recording id")]) { request in
        await model.requestTranscript(request["id"] as? String ?? "")
        return controlState(model, recorder)
    }
    service.register("mark", help: "Mark this moment of the running recording, with an optional note.", arguments: [.init("note", "what happens now")]) { request in
        guard recorder.isRecording else { throw ControlError("nothing is being recorded") }
        let note = (request["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        recorder.mark(note: note)
        return controlState(model, recorder)
    }
    service.register("search", help: "Search titles, transcripts and notes.", arguments: [.init("text", "words to look for")]) { request in
        model.query = request["text"] as? String ?? ""
        await model.reload()
        return controlState(model, recorder)
    }
    service.register("open", help: "Open a recording: its notes, transcript and audio.", arguments: [.init("id", "a recording id from state")]) { request in
        let id = request["id"] as? String ?? ""
        guard model.recordings.contains(where: { $0.id == id }) else { throw ControlError("recording \(id) is not in the list; show or search first") }
        model.selectedId = id
        await model.detailLoad?.value
        return controlState(model, recorder)
    }
    service.register("rename", help: "Give one of your own recordings a better title.", arguments: [.init("id", "a recording id"), .init("title", "the new title")]) { request in
        await model.rename(request["id"] as? String ?? "", to: request["title"] as? String ?? "")
        return controlState(model, recorder)
    }
    service.register("redo", help: "Write the transcript or the notes again, or think up a title; a new title keeps the notes.", arguments: [.init("id", "a recording id"), .init("step", "transcript, notes or title")]) { request in
        await model.redo(request["id"] as? String ?? "", step: request["step"] as? String ?? "notes")
        return controlState(model, recorder)
    }
    service.register("share", help: "Share one of your recordings with someone in the household; the person approves first.", arguments: [.init("id", "a recording id"), .init("person", "their name")]) { request in
        let id = request["id"] as? String ?? ""
        let name = request["person"] as? String ?? ""
        guard let person = model.others.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw ControlError("nobody called \(name) in the household")
        }
        let title = model.recordings.first { $0.id == id }?.title ?? id
        guard await approveControlAction("Deel ‘\(title)’ met \(person.name)") else { throw ControlError("the person declined") }
        await model.share(id, with: person.id)
        return controlState(model, recorder)
    }
    service.register("stop", help: "Stop the running recording; it is then uploaded and transcribed.") { _ in
        guard recorder.isRecording else { throw ControlError("nothing is being recorded") }
        await recorder.stop()
        return controlState(model, recorder)
    }
    service.register("import", help: "Queue the RecHoarder meetings in iCloud Drive › Meetings not imported before and start uploading them.") { _ in
        let (queued, waiting) = model.importRecHoarder()
        var state = controlState(model, recorder)
        state["imported"] = ["queued": queued, "waitingForICloud": waiting]
        return state
    }
    service.register("upload", help: "Try to send recordings that wait for an upload now.") { _ in
        await model.sendPending()
        return controlState(model, recorder)
    }
    service.register("mirror", help: "Bring the copy in iCloud Drive › Pensieve up to date now.") { _ in
        await model.mirrorNow()
        let last: Any = model.lastMirror.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        return ["lastMirror": last]
    }
}

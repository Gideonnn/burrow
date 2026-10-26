import Foundation
import Testing
@testable import LumosCore

enum Fixture {
    static let me = """
    {"person":{"id":"p1","name":"Ada"},"key":{"id":"k1","name":"Lumos op Testmac"},
     "rights":["read","organize"],"admin":true,"settings":{}}
    """
    static let status = #"{"dataOrigin":"fixture","catalogue":"Testgegevens"}"#

    static func title(_ id: Int, _ name: String, onList: Bool = false, trailer: Bool = false, type: String = "movie") -> String {
        """
        {"mediaType":"\(type)","tmdbId":\(id),"title":"\(name)","year":2020,"runtimeMinutes":95,"seasons":null,
         "genres":["Komedie"],"traits":["Warm"],"language":"Engels","poster":null,"backdrop":null,
         "availability":"available","hasTrailer":\(trailer),"onList":\(onList),"onShared":\(onList),"onMine":false,
         "pass":null,"taste":null,"match":null}
        """
    }

    static func rows(_ tonight: [String], list: [String] = []) -> String {
        """
        {"dataOrigin":"fixture","rows":[
         {"key":"tonight","title":"Voor jullie samen","subtitle":null,"style":"wide","items":[\(tonight.joined(separator: ","))],"empty":null},
         {"key":"list","title":"Onze lijst","subtitle":null,"style":"poster","items":[\(list.joined(separator: ","))],"empty":"Nog niets."}
        ]}
        """
    }

    static func detail(_ id: Int, _ name: String, trailer: String = "null", scores: String = "[]") -> String {
        String(title(id, name, trailer: trailer != "null").dropLast()) + """
        ,"dataOrigin":"fixture","synopsis":"Kort.","synopsisLanguage":"nl","credits":[],"scores":\(scores),
         "snippets":[],"trailer":\(trailer),"stills":[],"stillsCredit":null,"tmdbUrl":null}
        """
    }

    static let youtube = """
    {"provider":"youtube","key":"abc","url":"https://www.youtube.com/watch?v=abc","publisher":"Studio","language":"en","checkedAt":"2026-10-24"}
    """
}

/// A tiny server whose rows follow the test's list and verdicts.
final class Household: @unchecked Sendable {
    private let lock = NSLock()
    private var passed: Set<Int> = []
    private var listed: Set<Int> = []
    private var undo: [String: () -> Void] = [:]
    private var next = 0
    let titles = [(1, "Alpha"), (2, "Bravo"), (3, "Charlie")]

    func rows() -> String {
        lock.withLock {
            Fixture.rows(
                titles.filter { !passed.contains($0.0) }.map { Fixture.title($0.0, $0.1, onList: listed.contains($0.0)) },
                list: titles.filter { listed.contains($0.0) }.map { Fixture.title($0.0, $0.1, onList: true) })
        }
    }

    func change(_ apply: () -> Void, undo revert: @escaping () -> Void) -> String {
        lock.withLock {
            apply()
            next += 1
            undo["c\(next)"] = revert
            return #"{"changeId":"c\#(next)"}"#
        }
    }

    func pass(_ id: Int) -> String { change({ passed.insert(id) }, undo: { self.passed.remove(id) }) }
    func list(_ id: Int) -> String { change({ listed.insert(id) }, undo: { self.listed.remove(id) }) }

    func revert(_ id: String) -> (Int, String) {
        lock.withLock {
            guard let revert = undo.removeValue(forKey: id) else { return (404, #"{"error":"not found"}"#) }
            revert()
            return (200, #"{"changeId":"\#(id)"}"#)
        }
    }
}

@MainActor
@Suite(.serialized) struct LumosModelTests {
    func model(_ server: MockServer) -> LumosModel {
        let client = server.client()
        let model = LumosModel(
            store: ConnectionStore(service: "app.burrow.lumos.tests"), makeClient: { _ in client },
            connection: Connection(serverURL: URL(string: "http://burrow.test")!, token: "bk_test"))
        model.toastSeconds = nil
        model.progressSeconds = nil
        return model
    }

    func server(_ household: Household = Household()) -> MockServer {
        let server = MockServer()
        server.on("GET", "/api/me", json: Fixture.me)
        server.on("GET", "/api/lumos/status", json: Fixture.status)
        server.on("GET", "/api/lumos/rows") { _ in (200, household.rows()) }
        server.on("GET", "/api/lumos/lists/shared", json: #"{"scope":"shared","items":[]}"#)
        server.on("GET", "/api/lumos/lists/mine", json: #"{"scope":"mine","items":[]}"#)
        server.on("GET", "/api/lumos/verdicts", json: #"{"scope":"shared","items":[]}"#)
        for (id, name) in household.titles {
            let trailer = id == 1 ? Fixture.youtube : "null"
            server.on("GET", "/api/lumos/titles/movie/\(id)", json: Fixture.detail(id, name, trailer: trailer))
            server.on("GET", "/api/lumos/similar/movie/\(id)", json: #"{"dataOrigin":"fixture","items":[]}"#)
            server.on("PUT", "/api/lumos/lists/shared/items/movie/\(id)") { _ in (200, household.list(id)) }
        }
        server.on("POST", "/api/lumos/verdicts") { request in
            let body = request.httpBodyStream.map(readBody) ?? request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let id = body.contains(#""tmdbId":2"#) ? 2 : body.contains(#""tmdbId":3"#) ? 3 : 1
            return (201, household.pass(id))
        }
        server.on("POST", "/api/lumos/changes/c1/undo") { _ in household.revert("c1") }
        server.on("POST", "/api/lumos/changes/c2/undo") { _ in household.revert("c2") }
        return server
    }

    let alpha = TitleRef(mediaType: .movie, tmdbId: 1)
    let bravo = TitleRef(mediaType: .movie, tmdbId: 2)
    let charlie = TitleRef(mediaType: .movie, tmdbId: 3)

    func started(_ server: MockServer) async -> LumosModel {
        let model = model(server)
        await model.start()
        await model.show(.discover)
        return model
    }

    @Test func showsThatTheCatalogueIsTestData() async {
        let model = await started(server())
        #expect(model.isFixture)
        #expect(model.rows.map(\.key) == ["tonight", "list"])
        #expect(model.cursor == CardID(row: "tonight", ref: alpha))
    }

    @Test func arrowsMoveBetweenCardsAndRowsAndRememberTheColumn() async {
        let household = Household()
        let model = await started(server(household))
        _ = household.list(3)
        await model.reload()
        model.move(.right)
        model.move(.right)
        #expect(model.cursor == CardID(row: "tonight", ref: charlie))
        model.move(.down)
        #expect(model.cursor == CardID(row: "list", ref: charlie))
        model.move(.up)
        #expect(model.cursor == CardID(row: "tonight", ref: charlie))
        model.move(.home)
        #expect(model.cursor == CardID(row: "tonight", ref: alpha))
    }

    @Test func spaceShowsDetailsWithoutMovingFocus() async {
        let model = await started(server())
        model.move(.right)
        model.toggleInspector()
        #expect(model.inspected == bravo)
        #expect(model.focus == .content)
        #expect(model.cursor == CardID(row: "tonight", ref: bravo))
        model.toggleInspector()
        #expect(model.inspected == nil)
        #expect(model.cursor == CardID(row: "tonight", ref: bravo))
    }

    @Test func escapeClosesTheDetailsAndReturnsFocusToTheCard() async {
        let model = await started(server())
        model.move(.right)
        model.open(bravo, from: model.cursor, focusInside: true)
        #expect(model.focus == .inspector)
        model.escape()
        #expect(model.inspected == nil)
        #expect(model.focus == .content)
        #expect(model.cursor == CardID(row: "tonight", ref: bravo))
    }

    @Test func notNowSendsTheReasonOrNoneAndUndoReturnsFocus() async {
        let server = server()
        let model = await started(server)
        model.move(.right)
        await model.notNow(reason: "Niet ons ding")
        #expect(server.requests("POST", "/api/lumos/verdicts").last?.contains(#""reason":"Niet ons ding""#) == true)
        #expect(model.rows.first?.items.map(\.ref) == [alpha, charlie])
        // The cursor takes the card that moved into its place.
        #expect(model.cursor == CardID(row: "tonight", ref: charlie))
        #expect(model.toast?.canUndo == true)

        await model.undo()
        #expect(server.requests("POST", "/api/lumos/changes/c1/undo").count == 1)
        #expect(model.rows.first?.items.map(\.ref) == [alpha, bravo, charlie])
        #expect(model.cursor == CardID(row: "tonight", ref: bravo))

        model.move(.left)
        await model.notNow()
        let body = server.requests("POST", "/api/lumos/verdicts").last ?? ""
        #expect(body.contains(#""kind":"not-now""#))
        #expect(!body.contains("reason") || body.contains(#""reason":null"#))
    }

    @Test func yesPutsATitleOnTheListOfTheScopeAndUndoTakesItOff() async {
        let server = server()
        let model = await started(server)
        await model.toggleList()
        #expect(server.requests("PUT", "/api/lumos/lists/shared/items/movie/1").count == 1)
        #expect(model.rows.last?.items.map(\.ref) == [alpha])
        await model.undo()
        #expect(model.rows.last?.items.isEmpty == true)
        await model.undo()
        #expect(model.toast?.message == "Niets om ongedaan te maken.")
    }

    @Test func theReasonMenuTakesNoReasonOnEnterAndArrowsPickOne() async {
        let server = server()
        let model = await started(server)
        model.reasonMenu = alpha
        await model.chooseReason()
        #expect(server.requests("POST", "/api/lumos/verdicts").last?.contains(#""kind":"not-now""#) == true)
        #expect(model.reasonMenu == nil)

        model.reasonMenu = bravo
        model.moveReason(by: 1)
        await model.chooseReason()
        #expect(server.requests("POST", "/api/lumos/verdicts").last?.contains(#""kind":"seen""#) == true)

        model.reasonMenu = charlie
        model.moveReason(by: -1)
        await model.chooseReason()
        #expect(server.requests("POST", "/api/lumos/verdicts").last?.contains(#""reason":"Eén van ons wil niet""#) == true)
    }

    @Test func seenIsItsOwnVerdict() async {
        let server = server()
        let model = await started(server)
        await model.seen(bravo)
        #expect(server.requests("POST", "/api/lumos/verdicts").last?.contains(#""kind":"seen""#) == true)
    }

    @Test func theTrailerStartsOnlyOnRequestAndStopsOnEveryExit() async {
        let model = await started(server())
        model.open(alpha, from: model.cursor, focusInside: true)
        await model.detailTaskForTests?.value
        #expect(model.player == nil)

        await model.playTrailer()
        #expect(model.player?.ref == alpha)
        #expect(model.player?.status == .loading)
        // A loaded player is not playing; only its own report says so.
        model.playerReported(.loaded, for: alpha)
        #expect(model.player?.statusText.contains("nog niet gemeld") == true)
        model.playerReported(.playing, for: alpha)
        #expect(model.player?.status == .playing)

        model.escape()
        #expect(model.player == nil)
        #expect(model.inspected == alpha)

        await model.playTrailer()
        model.open(bravo, from: nil, focusInside: false)
        #expect(model.player == nil)
        model.playerReported(.playing, for: alpha)
        #expect(model.player == nil)

        await model.playTrailer(alpha)
        model.closeInspector()
        #expect(model.player == nil)
    }

    @Test func aTitleWithoutTrailerSaysSoInsteadOfPlaying() async {
        let model = await started(server())
        await model.playTrailer(bravo)
        #expect(model.player == nil)
        #expect(model.toast?.message == "Geen trailer gekoppeld voor Bravo.")
    }

    @Test func switchingScopeKeepsTheCardWhenItIsStillThere() async {
        let model = await started(server())
        model.move(.right)
        model.scope = .mine
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.cursor == CardID(row: "tonight", ref: bravo))
    }

    @Test func aMoodNarrowsByGenreAndTraitOnly() {
        let quiet = TitleSummary(
            mediaType: .movie, tmdbId: 9, title: "Lang en rustig", year: 2020, runtimeMinutes: 240, seasons: nil,
            genres: ["Drama"], traits: ["Rustig tempo"], language: nil, poster: nil, backdrop: nil, availability: .available,
            hasTrailer: false, onList: false, onShared: false, onMine: false, pass: nil, taste: nil, match: nil)
        #expect(LumosModel.Mood.calm.matches(quiet))
        #expect(!LumosModel.Mood.light.matches(quiet))
        #expect(LumosModel.Mood.all.matches(quiet))
    }

    @Test func decodesATitleWithoutScoresOrTrailer() throws {
        let detail = try APIClient.decoder.decode(TitleDetail.self, from: Data(Fixture.detail(2, "Bravo").utf8))
        #expect(detail.scores.isEmpty)
        #expect(detail.trailer == nil)
        let withScore = try APIClient.decoder.decode(TitleDetail.self, from: Data(Fixture.detail(
            1, "Alpha", trailer: Fixture.youtube,
            scores: #"[{"source":"Rotten Tomatoes","label":"Audience","value":89,"scale":"percent","votes":2500,"votesAtLeast":true,"asOf":"2026-10-24","url":null}]"#
        ).utf8))
        #expect(withScore.scores.first?.valueText == "89%")
        #expect(withScore.scores.first?.votesText == "2.500+ stemmen")
        #expect(withScore.trailer?.publisher == "Studio")
    }

    @Test func saysWhatHappenedToTheRequestAndHowFarTheDownloadIs() throws {
        func decode(_ extra: String) throws -> TitleDetail {
            var json = Fixture.detail(3, "Charlie")
            json.removeLast()
            return try APIClient.decoder.decode(TitleDetail.self, from: Data((json + "," + extra + "}").utf8))
        }
        let waiting = try decode(#""request":{"status":"pending","seasons":[1],"error":null,"attempts":0,"nextAttemptAt":"2026-10-25T15:00:15.000Z","updatedAt":"2026-10-25T15:00:00.000Z"},"download":null"#)
        #expect(waiting.request?.label == "Wordt zo aangevraagd (seizoen 1). Z maakt het ongedaan.")
        let down = try decode(#""request":{"status":"pending","seasons":null,"error":"Seerr is niet bereikbaar","attempts":2,"nextAttemptAt":null,"updatedAt":"2026-10-25T15:00:00.000Z"},"download":{"progress":0.42,"eta":null}"#)
        #expect(down.request?.label == "Seerr is niet bereikbaar. Lumos probeert het opnieuw.")
        #expect(down.download?.progress == 0.42)
        let old = try APIClient.decoder.decode(TitleDetail.self, from: Data(Fixture.detail(4, "Delta").utf8))
        #expect(old.request == nil && old.download == nil)
    }
}

private func readBody(_ stream: InputStream) -> String {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return String(decoding: data, as: UTF8.self)
}

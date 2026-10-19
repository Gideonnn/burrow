import Foundation
import Testing
@testable import HedwigCore

/// A window as the accessibility tree would report it, with a log of what the
/// service did to it.
@MainActor
final class FakeSurface: ControlSurface {
    var root: [ControlNode]
    private(set) var pressed: [String] = []
    private(set) var typed: [(String, String)] = []

    init(_ root: [ControlNode]) { self.root = root }

    func snapshot() -> [ControlNode] { root }
    func press(_ node: ControlNode) throws { pressed.append(node.label ?? "") }
    func type(_ node: ControlNode, _ text: String) throws { typed.append((node.label ?? "", text)) }
    func select(_ node: ControlNode) throws { pressed.append("select \(node.label ?? "")") }
}

@MainActor
@Suite struct ControlServiceTests {
    private func window() -> [ControlNode] {
        [ControlNode(role: "AXWindow", label: "Hedwig", children: [
            ControlNode(role: "AXTextField", label: "Serveradres", value: "https://burrow.example.com"),
            ControlNode(role: "AXTextField", subrole: "AXSecureTextField", label: "API-sleutel", value: "bk_secret"),
            ControlNode(role: "AXStaticText", identifier: "hedwig.secret", label: "Sleutel", value: "bk_created"),
            ControlNode(role: "AXStaticText", value: "Je ziet hem maar één keer.\n\nbk_Q2hhbmdlTWVQbGVhc2VJdHNBVGVzdA"),
            ControlNode(role: "AXButton", identifier: "hedwig.secret.copy", label: "Kopieer"),
            ControlNode(role: "AXButton", label: "Archiveer"),
            ControlNode(role: "AXButton", identifier: "hedwig.send", label: "Verstuur"),
            ControlNode(role: "AXMenuItem", label: "Verwijder"),
        ])]
    }

    private func service(_ surface: FakeSurface, approve: Bool = true) -> (ControlService, () -> [String]) {
        var asked: [String] = []
        let service = ControlService(surface: surface, state: { ["selection": "inbox"] }) { action in
            asked.append(action)
            return approve
        }
        return (service, { asked })
    }

    private func call(_ service: ControlService, _ json: String) async throws -> [String: Any] {
        let data = await service.handle(Data(json.utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func tree(_ service: ControlService) async throws -> String {
        let response = try await call(service, #"{"cmd":"tree"}"#)
        let data = try JSONSerialization.data(withJSONObject: response["result"] ?? [])
        return String(decoding: data, as: UTF8.self)
    }

    private func locate(_ label: String, in service: ControlService) async throws -> String {
        let response = try await call(service, #"{"cmd":"find","text":"\#(label)"}"#)
        let matches = try #require(response["result"] as? [[String: Any]])
        return try #require(matches.first?["id"] as? String)
    }

    @Test func theTreeNeverShowsPasswordsOrSecrets() async throws {
        let (service, _) = service(FakeSurface(window()))
        let tree = try await tree(service)
        #expect(tree.contains("burrow.example.com"))
        #expect(!tree.contains("bk_secret"))
        #expect(!tree.contains("bk_created"))
        #expect(!tree.contains("bk_Q2hhbmdl"))
        #expect(tree.contains("API-sleutel"))
    }

    @Test func typingIntoAPasswordFieldIsRefused() async throws {
        let surface = FakeSurface(window())
        let (service, _) = service(surface)
        let id = try await locate("API-sleutel", in: service)
        let response = try await call(service, #"{"cmd":"type","id":"\#(id)","text":"bk_other"}"#)
        #expect(response["ok"] as? Bool == false)
        #expect(surface.typed.isEmpty)

        let server = try await locate("Serveradres", in: service)
        _ = try await call(service, #"{"cmd":"type","id":"\#(server)","text":"https://x.example.com"}"#)
        #expect(surface.typed.map(\.1) == ["https://x.example.com"])
    }

    @Test func aButtonThatCopiesASecretCannotBePressed() async throws {
        let surface = FakeSurface(window())
        let (service, _) = service(surface)
        let id = try await locate("Kopieer", in: service)
        let response = try await call(service, #"{"cmd":"press","id":"\#(id)"}"#)
        #expect(response["ok"] as? Bool == false)
        #expect(surface.pressed.isEmpty)
    }

    @Test func anOrdinaryButtonIsPressedWithoutAsking() async throws {
        let surface = FakeSurface(window())
        let (service, asked) = service(surface)
        let id = try await locate("Archiveer", in: service)
        let response = try await call(service, #"{"cmd":"press","id":"\#(id)"}"#)
        #expect(response["ok"] as? Bool == true)
        #expect(surface.pressed == ["Archiveer"])
        #expect(asked().isEmpty)
    }

    @Test func sendingAndDeletingWaitForThePersonsApproval() async throws {
        let surface = FakeSurface(window())
        let (service, asked) = service(surface, approve: false)
        for label in ["Verstuur", "Verwijder"] {
            let id = try await locate(label, in: service)
            let response = try await call(service, #"{"cmd":"press","id":"\#(id)"}"#)
            #expect(response["ok"] as? Bool == false)
        }
        #expect(asked() == ["Verstuur", "Verwijder"])
        #expect(surface.pressed.isEmpty)

        let (approving, _) = self.service(surface, approve: true)
        let id = try await locate("Verstuur", in: approving)
        _ = try await call(approving, #"{"cmd":"press","id":"\#(id)"}"#)
        #expect(surface.pressed == ["Verstuur"])
    }

    @Test func anUnknownElementIsAnErrorNotACrash() async throws {
        let (service, _) = service(FakeSurface(window()))
        let response = try await call(service, #"{"cmd":"press","id":"w9/9"}"#)
        #expect(response["ok"] as? Bool == false)
        #expect((response["error"] as? String)?.isEmpty == false)
    }

    @Test func stateComesFromTheApp() async throws {
        let (service, _) = service(FakeSurface(window()))
        let response = try await call(service, #"{"cmd":"state"}"#)
        #expect((response["result"] as? [String: Any])?["selection"] as? String == "inbox")
    }
}

@MainActor
@Suite struct ControlSocketTests {
    @Test func aClientTalksToTheServerOverTheSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hc-\(UUID().uuidString.prefix(8)).sock").path
        let server = try ControlSocketServer(path: path) { request in
            Data(#"{"ok":true,"echo":\#(String(decoding: request, as: UTF8.self))}"#.utf8)
        }
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let reply = try await Task.detached { try ControlSocketClient(path: path).send(Data(#"{"cmd":"state"}"#.utf8)) }.value
        #expect(String(decoding: reply, as: UTF8.self) == #"{"ok":true,"echo":{"cmd":"state"}}"#)
    }
}

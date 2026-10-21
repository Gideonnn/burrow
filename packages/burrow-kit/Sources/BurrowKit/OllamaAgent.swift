import Foundation

/// Runs a request for a local model (`ollama:<name>`) through Ollama on this
/// Mac, with the answer constrained to the request's JSON schema. Nothing
/// leaves the Mac.
public struct OllamaAgent: AgentRunning {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public static func modelName(_ model: String) -> String {
        model.hasPrefix("ollama:") ? String(model.dropFirst("ollama:".count)) : model
    }

    public func run(_ request: AgentRequest) async throws -> Data {
        let name = Self.modelName(request.model)
        struct Message: Encodable { var role: String; var content: String }
        struct Options: Encodable { var temperature = 0; var num_ctx = 8192 }
        struct Body: Encodable {
            var model: String
            var stream = false
            var think = false
            var format: JSONValue
            var options = Options()
            var messages: [Message]
        }
        var http = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.timeoutInterval = Double(request.timeoutMs ?? 600_000) / 1000
        http.httpBody = try JSONEncoder().encode(Body(
            model: name, format: request.schema,
            messages: [Message(role: "system", content: request.system), Message(role: "user", content: request.prompt)]))
        let (data, response) = try await send(http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Reply: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message?
            var error: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if status == 404 || reply?.error?.contains("not found") == true {
            throw RunnerError.ollama("Het model \(name) staat niet op deze Mac: ollama pull \(name)")
        }
        guard status == 200, let content = reply?.message?.content else {
            throw RunnerError.ollama("Ollama faalde: \(reply?.error ?? "status \(status)")")
        }
        let answer = Data(content.utf8)
        guard (try? JSONSerialization.jsonObject(with: answer)) != nil else { throw RunnerError.invalidAnswer }
        return answer
    }

    /// The models Ollama has, as ollama:<name>; empty when Ollama is not running.
    public func installedModels() async -> [String] {
        var http = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        http.timeoutInterval = 5
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        guard let (data, _) = try? await send(http), let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map { "ollama:\($0.name)" }
    }

    /// Whether `model` is installed; a bare name also matches its `:latest` tag.
    public static func has(_ model: String, in installed: [String]) -> Bool {
        installed.contains(model) || installed.contains("\(model):latest")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw RunnerError.ollama("Ollama draait niet op deze Mac. Start de Ollama-app.")
        }
    }
}

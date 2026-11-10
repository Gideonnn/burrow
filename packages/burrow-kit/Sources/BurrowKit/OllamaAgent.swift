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
        if request.embed == true { return try await embed(request) }
        let name = Self.modelName(request.model)
        struct Message: Encodable { var role: String; var content: String }
        // A full answer is a few hundred tokens; the cap stops a model that
        // keeps repeating itself inside a string the schema cannot bound.
        struct Options: Encodable { var temperature = 0; var num_ctx = 8192; var num_predict = 1_024 }
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
        struct Reply: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message?
            var error: String?
        }
        let reply: Reply = try await send(http, model: name) { $0.error }
        guard let content = reply.message?.content else { throw RunnerError.ollama("Ollama faalde: \(reply.error ?? "status 200")") }
        let answer = Data(content.utf8)
        guard (try? JSONSerialization.jsonObject(with: answer)) != nil else { throw RunnerError.invalidAnswer }
        return answer
    }

    /// Vectors for search by meaning, cut to the first `dims` numbers.
    func embed(_ request: AgentRequest) async throws -> Data {
        struct Input: Decodable { var texts: [String]; var dims: Int? }
        guard let input = try? JSONDecoder().decode(Input.self, from: Data(request.prompt.utf8)) else { throw RunnerError.invalidAnswer }
        let vectors = try await embed(input.texts, model: request.model, dims: input.dims)
        return try JSONSerialization.data(withJSONObject: ["vectors": vectors])
    }

    public func embed(_ texts: [String], model: String, dims: Int? = nil) async throws -> [[Double]] {
        struct Body: Encodable { var model: String; var input: [String]; var truncate = true }
        struct Reply: Decodable { var embeddings: [[Double]]?; var error: String? }
        var http = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.timeoutInterval = 300
        http.httpBody = try JSONEncoder().encode(Body(model: Self.modelName(model), input: texts))
        let reply: Reply = try await send(http, model: Self.modelName(model)) { $0.error }
        guard let vectors = reply.embeddings, vectors.count == texts.count else {
            throw RunnerError.ollama("Ollama faalde: \(reply.error ?? "status 200")")
        }
        return vectors.map { v in dims.map { Array(v.prefix($0)) } ?? v }
    }

    /// The models Ollama has, as ollama:<name>; empty when Ollama is not running.
    public func installedModels() async -> [String] {
        var http = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        http.timeoutInterval = 5
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        guard let (data, _) = try? await data(http), let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map { "ollama:\($0.name)" }
    }

    /// Whether `model` is installed; a bare name also matches its `:latest` tag.
    public static func has(_ model: String, in installed: [String]) -> Bool {
        installed.contains(model) || installed.contains("\(model):latest")
    }

    /// The reply of a 200; a missing model and any other failure as Ollama words them.
    private func send<Reply: Decodable>(_ request: URLRequest, model: String, error: (Reply) -> String?) async throws -> Reply {
        let (data, response) = try await data(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        let message = reply.flatMap(error)
        if status == 404 || message?.contains("not found") == true {
            throw RunnerError.ollama("Het model \(model) staat niet op deze Mac: ollama pull \(model)")
        }
        guard status == 200, let reply else { throw RunnerError.ollama("Ollama faalde: \(message ?? "status \(status)")") }
        return reply
    }

    private func data(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw RunnerError.ollama("Ollama draait niet op deze Mac. Start de Ollama-app.")
        }
    }
}

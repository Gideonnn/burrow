import BurrowKit
import Foundation

extension AppModel {
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The place in the sidebar as a search scope; nil for places without mail.
    public var placeScope: SearchScope? {
        switch selection {
        case .inbox(let id): SearchScope(mailboxId: id, folder: .inbox)
        case .folder(let folder, let id): SearchScope(mailboxId: id, folder: folder)
        case nil: .everywhere
        default: nil
        }
    }

    public var searchScope: SearchScope { searchEverywhere ? .everywhere : placeScope ?? .everywhere }

    func rerunSearch() {
        searchLoad?.cancel()
        searchLoad = Task { searchedByMeaning ? await rerunPlan() : await searchWords() }
    }

    /// Word search as you type, after a short pause; an empty field brings the list back.
    func searchWords() async {
        let query = searchQuery
        let tokens = searchTokens
        searchExplanation = nil
        aiSearching = false
        searchedByMeaning = false
        planTokens = []
        searchAnswer = nil
        searchRanking = false
        lastPlan = nil
        droppedPlanKeys = []
        guard isSearching else {
            searchEverywhere = false
            searchTotal = 0
            await loadSelection(keepSelection: true)
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, let api else { return }
        do {
            let scope = searchScope
            let response = try await api.search(query, in: scope, filters: SearchFilters(tokens: tokens), includeLow: searchIncludesLow)
            guard !Task.isCancelled, query == searchQuery, tokens == searchTokens, scope == searchScope else { return }
            searchTotal = response.total ?? response.results.count
            searchLoose = response.loose ?? false
            showResults(response.results)
        } catch {
            if !Task.isCancelled { report(error, quiet: true) }
        }
    }

    private var chosenKeys: Set<String> { Set(searchTokens.map { $0.id }) }

    /// Offers chips for what is being typed: people after @, periods, kinds of mail.
    func suggest() {
        suggestionLoad?.cancel()
        typedBeforeChip = searchText
        let chosen = chosenKeys
        if let mention = SearchWords.mention(in: searchText) {
            suggestionLoad = Task {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let api, let people = try? await api.people(mention) else { return }
                guard !Task.isCancelled, SearchWords.mention(in: searchText) == mention else { return }
                searchSuggestions = people.map { SearchSuggestion(token: $0.token, detail: $0.detail) }.filter { !chosen.contains($0.id) }
            }
        } else {
            searchSuggestions = SearchWords.suggestions(for: searchText).filter { !chosen.contains($0.id) }
        }
    }

    /// Lenses over the results: people, kinds, attachments and years to narrow to.
    public var searchLenses: [SearchLens] {
        let own = Set((me?.mailboxes ?? []).map { $0.address.lowercased() })
        // The best thirty: further down the list a search by meaning is loose.
        return SearchWords.lenses(for: Array(bestResults.prefix(30)), own: own, chosen: searchTokens)
    }

    public func addSearchToken(_ token: SearchToken) {
        guard !chosenKeys.contains(token.id) else { return }
        searchTokens.append(token)
    }

    /// Drops one of the bot's chips and runs its plan again without it; no new plan.
    public func removePlanToken(_ token: SearchToken) {
        droppedPlanKeys.append(token.id)
        planTokens.removeAll { $0.id == token.id }
        searchAnswer = nil
        searchLoad?.cancel()
        searchLoad = Task { await rerunPlan() }
    }

    /// Search by meaning (Enter in the search field): the bot plans the search on the server.
    public func searchWithAI() async {
        searchLoad?.cancel()
        suggestionLoad?.cancel()
        searchSuggestions = []
        await askBot()
    }

    private func askBot() async {
        let question = searchQuery
        guard !question.isEmpty, let api else { return }
        let scope = searchScope
        let tokens = searchTokens
        searchedByMeaning = true
        aiSearching = true
        searchAnswer = nil
        planTokens = []
        lastPlan = nil
        droppedPlanKeys = []
        defer { if question == searchQuery, scope == searchScope { aiSearching = false } }
        do {
            let vector = await questionVector(question)
            let response = try await api.aiSearch(
                question, in: scope, filters: SearchFilters(tokens: tokens), includeLow: searchIncludesLow,
                vector: vector.map { ("ollama:embeddinggemma", $0) })
            guard question == searchQuery, scope == searchScope, tokens == searchTokens else { return }
            show(response)
            aiSearching = false
            await rank(question: question, wantsAnswer: response.wantsAnswer ?? false)
        } catch {
            if question == searchQuery, scope == searchScope { report(error) }
        }
    }

    /// The last plan again, with the chips the person kept; the bot is not asked.
    private func rerunPlan() async {
        guard let plan = lastPlan, let api else { return await askBot() }
        let question = searchQuery
        let scope = searchScope
        let tokens = searchTokens
        do {
            let response = try await api.aiSearch(
                question, in: scope, filters: SearchFilters(tokens: tokens), includeLow: searchIncludesLow,
                plan: plan, without: droppedPlanKeys)
            guard !Task.isCancelled, question == searchQuery, scope == searchScope, tokens == searchTokens else { return }
            show(response)
        } catch {
            if !Task.isCancelled { report(error, quiet: true) }
        }
    }

    private func show(_ response: SearchResponse) {
        searchLoose = false
        searchExplanation = response.explanation
        planTokens = response.tokens ?? []
        if let plan = response.plan, plan != .null { lastPlan = plan }
        // The list is what the passes fused; the server's total counts loose matches too.
        searchTotal = response.results.count
        showResults(response.results)
    }

    /// The bot reads the best thirty, orders them and answers when the question asks.
    private func rank(question: String, wantsAnswer: Bool) async {
        let ids = bestResults.prefix(30).map(\.id)
        guard ids.count >= 2, let api else { return }
        searchRanking = true
        defer { if question == searchQuery { searchRanking = false } }
        guard let ranked = try? await api.rank(question, ids: ids, answer: wantsAnswer), question == searchQuery else { return }
        let rest = bestResults.filter { m in !ranked.results.contains { $0.id == m.id } }
        searchAnswer = ranked.answer
        showResults(ranked.results + rest)
        if let first = ranked.answer?.messageIds.first, searchSort == .best { selectedMessageId = first }
    }

    /// The question's meaning from Ollama on this Mac, or nil within two seconds.
    private func questionVector(_ question: String) async -> [Double]? {
        let embed = embedQuestion
        return await withTaskGroup(of: [Double]?.self) { group in
            group.addTask { await embed(question) }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func showResults(_ results: [MessageSummary]) {
        bestResults = results
        sortResults()
    }

    func sortResults() {
        messages = searchSort == .newest ? bestResults.sorted { $0.receivedAt > $1.receivedAt } : bestResults
        keepOnlyListedSelection()
    }
}

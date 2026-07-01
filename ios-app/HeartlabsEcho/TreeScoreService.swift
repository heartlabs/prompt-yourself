import Foundation

// MARK: - Tree State

/// The state the tree screen renders from.
enum TreeState: Equatable {
    case loading
    case ready(TreeScore)   // includes the genuine near-empty tree (low / no data)
    case error(String)      // malformed LLM output or call failure → NO tree
}

// MARK: - TreeScoreService

/// Computes the four life-category scores from recent journal entries, with a
/// once-per-day cache. Past conversations only (today is excluded so it can't
/// bust the cache). Prefers each day's summary, falls back to its transcript.
///
/// Caching rule (matches the handoff):
/// - Rebuild **at most once per day**, and **only when a new past entry exists**.
/// - Malformed LLM output → retry once → otherwise an error state with no tree.
/// - No/low data → an all-zero score (the intended budding tree), no LLM call.
@MainActor
final class TreeScoreService {
    private let conversationService: ConversationService
    private let router: ModelRouter

    private let lookbackDays = 30
    private let maxEntries = 10
    private let cacheKey = "tree_score_cache_v1"

    init(conversationService: ConversationService, router: ModelRouter = ModelRouter()) {
        self.conversationService = conversationService
        self.router = router
    }

    // MARK: - Public API

    /// Returns the cached score when valid, otherwise computes a fresh one.
    /// - Parameter force: when `true`, bypasses the cache (used by pull-to-refresh).
    func loadOrCompute(force: Bool = false) async -> TreeState {
        let today = ConversationService.todayDateKey
        let entries = gatherEntries()
        let signature = inputSignature(for: entries)

        // Cache check.
        if !force, let cached = loadCache() {
            // Already computed today → at most once per day.
            if cached.computedDate == today {
                return .ready(cached)
            }
            // New day but no new past entry → keep the cached scores, just
            // refresh the date so we don't recompute again until inputs change.
            if cached.inputSignature == signature {
                var refreshed = cached
                refreshed.computedDate = today
                saveCache(refreshed)
                return .ready(refreshed)
            }
        }

        // No data → the genuine near-empty growing tree (no API call).
        if entries.isEmpty {
            let empty = TreeScore.empty(computedDate: today, inputSignature: signature)
            saveCache(empty)
            return .ready(empty)
        }

        // Compute via the LLM (retry once on malformed output).
        do {
            let scores = try await computeScores(from: entries)
            let result = TreeScore(scores: scores, computedDate: today, inputSignature: signature)
            saveCache(result)
            return .ready(result)
        } catch {
            return .error(treeErrorMessage(error))
        }
    }

    // MARK: - Gathering entries

    /// One day's journal entry condensed for scoring.
    private struct Entry {
        let dateKey: String
        let text: String       // summary preferred, else full transcript
        let usedSummary: Bool
    }

    /// Up to `maxEntries` past days within `lookbackDays`, today excluded,
    /// most recent first. Prefers a day's summary, falls back to its transcript.
    private func gatherEntries() -> [Entry] {
        let conversations = conversationService.fetchRecentConversations(days: lookbackDays)
            .filter { !$0.messages.isEmpty }
            .sorted { $0.dateKey > $1.dateKey }   // most recent first

        var entries: [Entry] = []
        for conv in conversations {
            if entries.count >= maxEntries { break }
            if let summary = conv.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(Entry(dateKey: conv.dateKey, text: summary, usedSummary: true))
            } else if let transcript = conversationService.fetchFullConversationText(dateKey: conv.dateKey),
                      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(Entry(dateKey: conv.dateKey, text: transcript, usedSummary: false))
            }
        }
        return entries
    }

    /// A signature of the inputs; changes when a new past entry exists or a
    /// day's available text changes (e.g. a summary was generated since).
    private func inputSignature(for entries: [Entry]) -> String {
        entries
            .map { "\($0.dateKey):\($0.usedSummary ? "s" : "t"):\($0.text.count)" }
            .joined(separator: "|")
    }

    // MARK: - LLM scoring

    private func computeScores(from entries: [Entry]) async throws -> [String: Int] {
        let system = scoringSystemPrompt()
        let user = scoringUserPrompt(entries: entries)
        let request: ChatHistory = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user),
        ]

        // Attempt + one retry on malformed output.
        var lastError: Error = TreeScoreError.malformed
        for attempt in 0..<2 {
            do {
                let response = try await router.sendMessages(request, tier: .cheap, jsonMode: true)
                guard case .text(let content) = response else {
                    lastError = TreeScoreError.malformed
                    continue
                }
                if let scores = Self.parseScores(content) {
                    return scores
                }
                lastError = TreeScoreError.malformed
            } catch {
                lastError = error
            }
            if attempt == 0 { continue }  // retry once
        }
        throw lastError
    }

    /// Robustly extracts the four scores from the model's reply. Tolerates
    /// prose around the JSON by scanning from the first `{` to the last `}`.
    static func parseScores(_ raw: String) -> [String: Int]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        let jsonSlice = String(raw[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Accept either a flat object or one nested under "scores".
        let source: [String: Any]
        if let nested = obj["scores"] as? [String: Any] {
            source = nested
        } else {
            source = obj
        }

        var result: [String: Int] = [:]
        for category in LifeCategory.all {
            guard let value = Self.intValue(source[category.id]) else { return nil }
            result[category.zone.rawValue] = max(0, min(100, value))
        }
        return result
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int:
            return n
        case let d as Double:
            return Int(d.rounded())
        case let n as NSNumber:
            return n.intValue
        case let s as String:
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                return Int(d.rounded())
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Prompts

    private func scoringSystemPrompt() -> String {
        let categoryGuide = LifeCategory.all.map { cat in
            "- \(cat.id) — \(cat.title) (\(cat.subtitle)): covers \(cat.subItems.joined(separator: ", "))."
        }.joined(separator: "\n")

        return """
        You score how present and nourished four areas of a person's life are, based on their recent journal entries. You are warm, fair, and grounded — this is a reflection of balance, not a judgement.

        The four categories and what each covers:
        \(categoryGuide)

        How to score (0–100 per category, independent — they do NOT sum to 100):
        - Use a points model, summed across the entries provided. Per entry, add roughly: ~10 for a light/passing mention of a category, ~50 for a strong/meaningful engagement, up to ~80 for a very intense single moment (deep emotion, a milestone, sustained focus).
        - A high score can come EITHER from one very intense entry OR from light-but-regular mentions across several entries. Reward consistency as much as intensity.
        - Normalize intensity to THIS writer's own baseline tone. If someone writes emotionally about everything, calibrate to their norm so they don't get uniformly high scores; if someone is understated, don't under-score them. Judge salience relative to how they usually express themselves.
        - Few entries should yield modest scores — a sparse journal is a small, budding tree, and that is fine.
        - Map the summed points sensibly onto 0–100. Bands for intuition: 70–100 thriving, 30–69 growing, 0–29 needs attention.

        Output ONLY a JSON object, no prose, with exactly these integer keys (0–100):
        {"about_me": int, "work_goals": int, "family_relationships": int, "social_life": int}
        """
    }

    private func scoringUserPrompt(entries: [Entry]) -> String {
        let body = entries
            .sorted { $0.dateKey < $1.dateKey }  // chronological for the model
            .map { "### \($0.dateKey)\n\($0.text)" }
            .joined(separator: "\n\n")
        return """
        Here are the journal entries to score (\(entries.count) day\(entries.count == 1 ? "" : "s"), most within the last \(lookbackDays) days). Score the four categories per the rules and return only the JSON object.

        \(body)
        """
    }

    // MARK: - Cache (UserDefaults)

    private func loadCache() -> TreeScore? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let score = try? JSONDecoder().decode(TreeScore.self, from: data)
        else { return nil }
        return score
    }

    private func saveCache(_ score: TreeScore) {
        if let data = try? JSONEncoder().encode(score) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func treeErrorMessage(_ error: Error) -> String {
        if error is TreeScoreError {
            return "We couldn't read your tree this time. Please try again in a moment."
        }
        return (error as? LLMError)?.errorDescription
            ?? "We couldn't reach the scoring service. Please try again."
    }
}

enum TreeScoreError: Error {
    case malformed
}

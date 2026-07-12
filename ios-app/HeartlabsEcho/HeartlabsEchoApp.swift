import SwiftData
import SwiftUI

/// Holds all services constructed once at launch. Each service is a single
/// `let` — there is exactly one instance per kind in the entire app, fixing
/// the duplicate-`SummaryService`/duplicate-`ModelRouter` bug (P0.4).
struct AppServices {
    let modelContainer: ModelContainer
    let router: ModelRouter
    let conversationService: ConversationService
    let summaryService: SummaryService
    let goalService: GoalService
    let treeScoreService: TreeScoreService
}

@main
struct HeartlabsEchoApp: App {
    private let services: AppServices

    init() {
        // Build the ModelContainer manually so we can create services before
        // any view exists — every engine/VM receives non-optional dependencies
        // at init time, eliminating two-phase initialization everywhere.
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Conversation.self, Message.self, Goal.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let modelContext = container.mainContext
        let router = ModelRouter()
        let conversationService = ConversationService(modelContext: modelContext)
        let summaryService = SummaryService(conversationService: conversationService, kind: .journal, router: router)
        let goalService = GoalService(modelContext: modelContext)
        let treeScoreService = TreeScoreService(conversationService: conversationService, router: router)

        services = AppServices(
            modelContainer: container,
            router: router,
            conversationService: conversationService,
            summaryService: summaryService,
            goalService: goalService,
            treeScoreService: treeScoreService
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                conversationService: services.conversationService,
                summaryService: services.summaryService,
                goalService: services.goalService,
                treeScoreService: services.treeScoreService,
                router: services.router
            )
        }
        .modelContainer(services.modelContainer)
    }
}

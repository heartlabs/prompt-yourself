import SwiftData
import SwiftUI

@main
struct HeartlabsEchoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Conversation.self, Message.self])
    }
}

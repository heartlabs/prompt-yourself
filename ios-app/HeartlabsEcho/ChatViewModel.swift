import Foundation

/// The Journal (daily conversation) view model.
///
/// A thin subclass of `ConversationEngine` configured with `.journal`. All of the
/// conversation logic lives in the engine; this exists so the Journal screen has
/// a concrete, no-argument type to instantiate.
///
/// Transitional: a later phase moves both features to straight composition so
/// Journal and Dream use `ConversationEngine` symmetrically (no subclassing).
@MainActor
final class ChatViewModel: ConversationEngine {
    init() {
        super.init(configuration: .journal)
    }
}

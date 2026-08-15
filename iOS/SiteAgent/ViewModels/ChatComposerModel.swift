import Foundation
import SwiftUI

/// Shared composer attachments so the Chat transcript and root-owned composer
/// layer use one attachment collection. Draft text stays in SceneStorage.
@MainActor
final class ChatComposerModel: ObservableObject {
    static let shared = ChatComposerModel()

    @Published var attachments: [Attachment] = []

    private init() {}
}

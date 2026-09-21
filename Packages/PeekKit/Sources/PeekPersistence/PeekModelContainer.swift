import Foundation
import SwiftData

public enum PeekModelContainer {

    public static let schema = Schema([StoredConversation.self, StoredMessage.self])

    /// The on-disk store, under Application Support.
    ///
    /// An explicit URL rather than SwiftData's default so the file's location
    /// is documented, and so conversations — which contain the user's selected
    /// text — live somewhere predictable that can be deleted.
    public static func makeOnDisk() throws -> ModelContainer {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        let directory = support.appending(path: "Peek", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = ModelConfiguration(
            url: directory.appending(path: "Conversations.store")
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// In-memory store, for tests and previews.
    public static func makeInMemory() throws -> ModelContainer {
        try ModelContainer(for: schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

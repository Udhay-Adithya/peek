import Foundation

/// A provider-neutral request for an assistant turn.
///
/// Carries no provider-specific fields. Each adapter is responsible for
/// translating this into its own wire format, which is what stops the shape of
/// one vendor's API from becoming the shape of the whole app.
public struct AssistantRequest: Sendable, Equatable {
    public var model: String
    /// Steering applied outside the conversation itself.
    public var systemInstruction: String?
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxOutputTokens: Int?

    public init(model: String,
                systemInstruction: String? = nil,
                messages: [ChatMessage],
                temperature: Double? = nil,
                maxOutputTokens: Int? = nil) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.messages = messages
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable, CaseIterable {
        case user
        case assistant
    }

    public var role: Role
    public var parts: [ContentPart]

    public init(role: Role, parts: [ContentPart]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience for the common text-only case.
    public init(role: Role, text: String) {
        self.init(role: role, parts: [.text(text)])
    }

    /// Concatenated text of this message, ignoring non-text parts.
    public var plainText: String {
        parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined()
    }
}

public enum ContentPart: Sendable, Equatable {
    case text(String)
    case image(ImageAttachment)
}

/// An image supplied as conversation context.
///
/// Held as encoded bytes rather than a platform image type so the core stays
/// free of AppKit and so the size actually being sent is explicit at every
/// layer. Screenshots are downscaled and compressed before reaching here.
public struct ImageAttachment: Sendable, Equatable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }

    public var byteCount: Int { data.count }
}

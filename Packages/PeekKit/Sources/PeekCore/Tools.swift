import Foundation

/// One argument of a tool, as declared to a provider.
///
/// Deliberately flat primitives rather than a full JSON Schema model. Every
/// tool Peek ships takes a handful of scalars, and a complete schema type —
/// nested objects, arrays, enums, `oneOf` — would be a great deal of code with
/// no caller. If a tool ever needs structure, this is where it goes, and the
/// translation in each adapter is the only other place that must learn it.
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string, integer, number, boolean
    }

    public let name: String
    public let description: String
    public let kind: Kind
    public let isRequired: Bool

    public init(name: String, description: String, kind: Kind, isRequired: Bool) {
        self.name = name
        self.description = description
        self.kind = kind
        self.isRequired = isRequired
    }
}

/// A tool the model may call, declared once and translated per provider.
public struct ToolDefinition: Sendable, Equatable, Identifiable {
    public var id: String { name }

    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    /// Whether running this tool sends anything off this machine.
    ///
    /// Not cosmetic. Peek's privacy posture is that nothing leaves the Mac
    /// unless the user chose a cloud provider, and a tool that fetches a URL
    /// breaks that on the model's initiative rather than the user's. Tools
    /// marked here are withheld unless the user has opted in, so the model is
    /// never offered a capability the user has not granted.
    public let leavesTheMachine: Bool

    public init(name: String,
                description: String,
                parameters: [ToolParameter],
                leavesTheMachine: Bool) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.leavesTheMachine = leavesTheMachine
    }
}

/// The outcome of running a tool, sent back to the model.
public struct ToolResult: Sendable, Equatable {
    /// The call this answers. Optional because not every provider issues ids.
    public let callID: String?
    public let name: String
    /// The payload the model sees. Plain text; an adapter wraps it as that
    /// provider's wire format requires.
    public let content: String
    /// A failure the model should be told about rather than hidden from: a
    /// model that cannot tell "no results" from "the tool broke" will cheerfully
    /// invent the answer.
    public let isError: Bool

    public init(callID: String?, name: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }
}

/// Runs tool calls on the app's behalf.
///
/// A protocol in the core so the tool loop can be tested without a network, a
/// conversation store, or a real model.
public protocol ToolExecuting: Sendable {
    /// The tools to offer the model for this turn.
    var tools: [ToolDefinition] { get }
    /// Runs one call. Must not throw: a tool failure is reported to the model
    /// as a result, not raised as a stream error, so the turn can continue.
    func execute(_ call: ToolCall) async -> ToolResult
}

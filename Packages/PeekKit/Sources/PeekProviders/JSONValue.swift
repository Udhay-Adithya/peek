import Foundation

/// Raw JSON carried through the adapter without being understood.
///
/// Tool arguments arrive as whatever object the model produced and are handed
/// to the tool that owns the schema. Decoding them into a typed model here, and
/// re-encoding on the way back, would risk changing what the model said — key
/// order, number formatting, a field this adapter has never heard of. So the
/// bytes are kept and replayed verbatim.
struct JSONValue: Codable, Equatable, Sendable {
    let rawJSON: Data

    init(rawJSON: Data) {
        self.rawJSON = rawJSON
    }

    init?(rawJSON: Data?) {
        guard let rawJSON else { return nil }
        self.rawJSON = rawJSON
    }

    init(from decoder: Decoder) throws {
        // Re-serialising the decoded container is the only way to capture
        // arbitrary JSON through Codable without a full value tree.
        let container = try decoder.singleValueContainer()
        let any = try container.decode(AnyJSON.self)
        rawJSON = try JSONSerialization.data(withJSONObject: any.value,
                                             options: [.fragmentsAllowed, .sortedKeys])
    }

    func encode(to encoder: Encoder) throws {
        let object = try JSONSerialization.jsonObject(with: rawJSON,
                                                      options: [.fragmentsAllowed])
        var container = encoder.singleValueContainer()
        try container.encode(AnyJSON(value: object))
    }
}

/// Minimal bridge between `Codable` and `JSONSerialization`'s untyped objects.
private struct AnyJSON: Codable {
    let value: Any

    init(value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyJSON].self) {
            value = v.mapValues(\.value)
        } else if let v = try? c.decode([AnyJSON].self) {
            value = v.map(\.value)
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else if c.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as [String: Any]: try c.encode(v.mapValues(AnyJSON.init(value:)))
        case let v as [Any]:         try c.encode(v.map(AnyJSON.init(value:)))
        case let v as Bool:          try c.encode(v)
        case let v as Int:           try c.encode(v)
        case let v as Double:        try c.encode(v)
        case let v as String:        try c.encode(v)
        case is NSNull:              try c.encodeNil()
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: c.codingPath,
                                                          debugDescription: "unsupported JSON"))
        }
    }
}

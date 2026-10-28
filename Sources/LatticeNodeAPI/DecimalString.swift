import Foundation

/// A 64- or 128-bit consensus integer on the JSON wire: a canonical base-10
/// string (`0`, or an optional `-` then a nonzero digit then digits), never a
/// JSON number. JSON numbers lose precision above 2^53 in most clients, so
/// every such integer the node serves or accepts uses this one spelling. A
/// JSON number, a leading `+` or zero, `-0`, or an out-of-range value is a
/// decoding error.
@propertyWrapper
public struct DecimalString<Value: FixedWidthInteger & Sendable>: Codable, Sendable, Equatable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try decodeCanonicalDecimal(Value.self, from: container.decode(String.self)) {
            DecodingError.dataCorruptedError(in: container, debugDescription: $0)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(wrappedValue))
    }
}

/// `DecimalString` for an optional field. Nil is omitted from the object, not
/// written as `null`, and an absent key decodes as nil.
@propertyWrapper
public struct OptionalDecimalString<Value: FixedWidthInteger & Sendable>: Codable, Sendable, Equatable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        wrappedValue = try DecimalString<Value>(from: decoder).wrappedValue
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(String(wrappedValue))
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    public func decode<Value>(
        _ type: OptionalDecimalString<Value>.Type,
        forKey key: Key
    ) throws -> OptionalDecimalString<Value> {
        try decodeIfPresent(type, forKey: key) ?? OptionalDecimalString(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Value>(
        _ value: OptionalDecimalString<Value>,
        forKey key: Key
    ) throws {
        guard value.wrappedValue != nil else { return }
        try encodeIfPresent(value, forKey: key)
    }
}

/// Parses a canonical decimal string; `fail` builds the error for a
/// non-canonical or out-of-range spelling.
public func decodeCanonicalDecimal<Value: FixedWidthInteger>(
    _: Value.Type,
    from text: String,
    fail: (String) -> any Error
) throws -> Value {
    guard let value = Value(text, radix: 10), String(value) == text else {
        throw fail("expected a canonical decimal string for \(Value.self), got \"\(text)\"")
    }
    return value
}

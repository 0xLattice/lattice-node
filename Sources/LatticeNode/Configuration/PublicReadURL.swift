import Foundation

/// Far above any real base URL while keeping relayed self-declared strings
/// small on the wire and in per-peer state.
public let maximumPublicReadURLBytes = 2048

/// Normalize an operator-declared public read base URL. Invalid values are
/// omitted rather than turning a peer handshake into a protocol failure.
public func normalizedPublicReadURL(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard _isBoundedWireAtom(trimmed, maximumBytes: maximumPublicReadURLBytes),
          !trimmed.contains(where: { "\"'<>`\\".contains($0) }),
          var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil
    else { return nil }

    var normalized: String
    if components.scheme == scheme, host == host.lowercased() {
        normalized = trimmed
    } else {
        components.scheme = scheme
        components.host = host.lowercased()
        guard let rebuilt = components.string else { return nil }
        normalized = rebuilt
    }
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized.isEmpty ? nil : normalized
}

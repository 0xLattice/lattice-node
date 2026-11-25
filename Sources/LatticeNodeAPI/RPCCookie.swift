import Foundation

/// The `Authorization` value for the node's loopback RPC cookie file
/// (bitcoind's `__cookie__:<token>` content, sent as HTTP Basic), read fresh
/// each call: the node writes a new one at every start. Nil when unreadable.
public func rpcCookieAuthorization(file: URL) -> String? {
    guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let cookie = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cookie.isEmpty else { return nil }
    return "Basic " + Data(cookie.utf8).base64EncodedString()
}

import Foundation
import Hummingbird

/// The operator dashboard: a page, its stylesheet and its script, built into
/// the binary (`Dashboard/`, embedded by SwiftPM) and served by the operator
/// applications. The files carry no secret and are open to anyone who can
/// reach the listener; every request the page makes for data carries a token
/// (or the cookie) like any other client's.
enum Dashboard {
    struct Asset {
        let contentType: String
        let bytes: [UInt8]
    }

    static let assets: [String: Asset] = [
        "/": Asset(contentType: "text/html; charset=utf-8", bytes: PackageResources.index_html),
        "/dashboard.css": Asset(contentType: "text/css; charset=utf-8", bytes: PackageResources.dashboard_css),
        "/dashboard.js": Asset(contentType: "text/javascript; charset=utf-8", bytes: PackageResources.dashboard_js),
    ]

    /// Whether `request` asks for one of the dashboard's files: the only
    /// requests the operator applications answer without a credential, besides
    /// the loopback `/health`.
    static func isAsset(_ request: Request) -> Bool {
        request.method == .get && assets[request.uri.path] != nil
    }

    static func addRoutes<Context: RequestContext>(to router: Router<Context>) {
        for (path, asset) in assets {
            router.get(RouterPath(path)) { _, _ in
                Response(
                    status: .ok,
                    headers: [
                        .contentType: asset.contentType,
                        .cacheControl: "no-cache",
                        // The page holds a token: it runs only its own script
                        // and is never framed.
                        .contentSecurityPolicy: "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' http: https:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                        .xContentTypeOptions: "nosniff",
                    ],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: asset.bytes))
                )
            }
        }
    }
}

/// Whether a browser `Origin` names the listener the request reached: the
/// dashboard this listener served, calling back. Such a request still needs a
/// token or the cookie; a page from anywhere else is still refused unless its
/// operator listed its origin.
func isSameOrigin(_ origin: String, as request: Request) -> Bool {
    guard let schemeEnd = origin.range(of: "://") else { return false }
    let scheme = origin[..<schemeEnd.lowerBound].lowercased()
    let authority = origin[schemeEnd.upperBound...].lowercased()
    let hosts = Set(([request.head.authority].compactMap { $0 }
        + request.headers.filter { $0.name.canonicalName == "host" }.map(\.value)).map { $0.lowercased() })
    guard !hosts.isEmpty, !authority.isEmpty else { return false }
    let defaultPort = scheme == "https" ? ":443" : scheme == "http" ? ":80" : nil
    // Every name the request carries for this listener must be the origin's.
    return hosts.allSatisfy { host in
        host == authority || defaultPort.map { host == authority + $0 || host + $0 == authority } == true
    }
}

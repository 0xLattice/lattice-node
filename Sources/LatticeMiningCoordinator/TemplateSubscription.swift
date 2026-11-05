import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LatticeMinerCore

// `POST /mining/templates/subscribe`: the node's server-sent template events,
// read over URLSession's data delegate, which corelibs Foundation streams on
// Linux as well.

extension HTTPMiningCoordinatorNodeClient {
    /// The node's templates as it builds them, reconnecting when the
    /// connection drops. A reconnect's first push is clean: what moved while
    /// it was down is unknown. Ends on an unauthorized or missing route, or
    /// a refused subscription.
    public func templates() -> AsyncThrowingStream<MiningCoordinatorPush, any Error>? {
        AsyncThrowingStream { continuation in
            let task = Task {
                var backoff = Duration.milliseconds(250)
                while !Task.isCancelled {
                    do {
                        for try await event in self.templateEvents() {
                            // The node refused the subscription (busy, or
                            // the chain is gone): fetch instead.
                            if event.name == "end" { throw MiningCoordinatorNodeClientError.subscriptionUnavailable }
                            guard event.name == "template" else { continue }
                            let work = try JSONDecoder().decode(TemplateResponse.self, from: event.data)
                            struct Clean: Decodable { let clean: Bool? }
                            guard let pushed = MiningCoordinatorWork(template: work) else { continue }
                            let clean = (try? JSONDecoder().decode(Clean.self, from: event.data).clean) ?? true
                            continuation.yield(MiningCoordinatorPush(work: pushed, clean: clean))
                            backoff = .milliseconds(250)
                        }
                    } catch let error as MiningCoordinatorNodeClientError {
                        switch error {
                        case .unauthorized, .subscriptionUnavailable:
                            continuation.finish(throwing: error)
                            return
                        case .nonHTTPResponse, .invalidSubmissionResponse:
                            break
                        }
                    } catch {}
                    // The connection ended: a transport matter, retried.
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One connection's events, until it ends.
    private func templateEvents() -> AsyncThrowingStream<ServerSentEvent, any Error> {
        var request = self.request("mining/templates/subscribe")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = templateRequestBody
        // The node writes a keepalive comment every 15 s, so a connection
        // silent for longer than this is dead, whatever the chain does.
        request.timeoutInterval = 60
        return AsyncThrowingStream { continuation in
            let delegate = ServerSentEventsDelegate(continuation)
            let session = URLSession(configuration: self.session.configuration, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
            continuation.onTermination = { _ in session.invalidateAndCancel() }
        }
    }
}

/// One server-sent event: its `event:` name and its `data:` lines joined.
struct ServerSentEvent: Sendable, Equatable {
    var name = "message"
    var data = Data()
}

/// The `text/event-stream` framing: lines, a blank line ends an event, and a
/// line starting with `:` is a comment.
struct ServerSentEventParser {
    private var buffer = Data()
    private var event = ServerSentEvent()
    private var hasData = false

    mutating func feed(_ bytes: Data) -> [ServerSentEvent] {
        buffer.append(bytes)
        var events: [ServerSentEvent] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.isEmpty {
                if hasData { events.append(event) }
                event = ServerSentEvent()
                hasData = false
                continue
            }
            guard line.first != UInt8(ascii: ":") else { continue }
            let text = String(decoding: line, as: UTF8.self)
            let (field, value) = text.firstIndex(of: ":").map { colon in
                let rest = text[text.index(after: colon)...]
                return (String(text[..<colon]), String(rest.hasPrefix(" ") ? rest.dropFirst() : rest))
            } ?? (text, "")
            switch field {
            case "event":
                event.name = value
            case "data":
                if hasData { event.data.append(UInt8(ascii: "\n")) }
                event.data.append(contentsOf: Data(value.utf8))
                hasData = true
            default:
                break
            }
        }
        return events
    }
}

private final class ServerSentEventsDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<ServerSentEvent, any Error>.Continuation
    private let lock = NSLock()
    private var parser = ServerSentEventParser()

    init(_ continuation: AsyncThrowingStream<ServerSentEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: MiningCoordinatorNodeClientError.nonHTTPResponse)
            return completionHandler(.cancel)
        }
        switch http.statusCode {
        case 200:
            return completionHandler(.allow)
        case 401, 403:
            continuation.finish(throwing: MiningCoordinatorNodeClientError.unauthorized(statusCode: http.statusCode))
        case 404:
            continuation.finish(throwing: MiningCoordinatorNodeClientError.subscriptionUnavailable)
        default:
            continuation.finish(
                throwing: MiningCoordinatorNodeClientError.invalidSubmissionResponse(statusCode: http.statusCode)
            )
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let events = parser.feed(data)
        lock.unlock()
        for event in events { continuation.yield(event) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

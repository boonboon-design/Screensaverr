import Foundation
import Network

/// A minimal HTTP/1.1 client built on Network.framework, used for `http://` URLs.
///
/// Screen savers run inside Apple's `legacyScreenSaver` host, so App Transport Security
/// is governed by *its* Info.plist, not ours, and plain-HTTP requests made with URLSession
/// can be refused. Home servers (Sonarr on `http://192.168.1.10:8989`, …) are almost always
/// plain HTTP, so we speak HTTP ourselves over a raw TCP connection, which ATS doesn't cover.
final class PlainHTTPTransport: HTTPTransport, @unchecked Sendable {
    static let userAgent = "Screensaverr/1.0"

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let host = request.url.host, !host.isEmpty else { throw HTTPError.invalidURL }
        let defaultPort = request.url.scheme?.lowercased() == "https" ? 443 : 80
        let portNumber = request.url.port ?? defaultPort
        guard (1...65535).contains(portNumber),
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber))
        else { throw HTTPError.invalidURL }

        let payload = Self.serialize(request, host: host, port: portNumber, defaultPort: defaultPort)
        let exchange = PlainHTTPExchange(
            host: NWEndpoint.Host(host),
            port: port,
            payload: payload,
            timeout: request.timeout,
            isHeadRequest: request.method.uppercased() == "HEAD"
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(continuation)
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    static func serialize(_ request: HTTPRequest, host: String, port: Int, defaultPort: Int) -> Data {
        var target = "/"
        if let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
            let path = components.percentEncodedPath
            target = path.isEmpty ? "/" : path
            if let query = components.percentEncodedQuery, !query.isEmpty {
                target += "?" + query
            }
        }
        let hostForHeader = host.contains(":") ? "[\(host)]" : host
        let hostHeader = port == defaultPort ? hostForHeader : "\(hostForHeader):\(port)"

        var headers: [(String, String)] = [
            ("Host", hostHeader),
            ("User-Agent", userAgent),
            ("Accept", "application/json, */*"),
            ("Accept-Encoding", "identity"),
            ("Connection", "close"),
        ]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            if let index = headers.firstIndex(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers[index] = (name, value)
            } else {
                headers.append((name, value))
            }
        }

        var text = "\(request.method.uppercased()) \(target) HTTP/1.1\r\n"
        for (name, value) in headers {
            // Never let a value smuggle in extra header lines.
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            text += "\(name): \(clean)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// One request/response over one TCP connection. All state is confined to `queue`.
private final class PlainHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Screensaverr.PlainHTTPExchange")
    private let payload: Data
    private let timeout: TimeInterval
    private let isHeadRequest: Bool

    private var buffer = Data()
    private var head: HTTPResponseHead?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var finished = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, payload: Data, timeout: TimeInterval, isHeadRequest: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(1, min(timeout, 30)))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: host, port: port, using: parameters)
        self.payload = payload
        self.timeout = timeout
        self.isHeadRequest = isHeadRequest
    }

    func start(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
        queue.async {
            if self.finished {
                continuation.resume(throwing: HTTPError.cancelled)
                return
            }
            self.continuation = continuation
            self.connection.stateUpdateHandler = { [self] state in
                self.handle(state)
            }
            self.connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                self?.finish(.failure(HTTPError.timedOut))
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(HTTPError.cancelled)) }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: payload, completion: .contentProcessed { [self] error in
                if let error { self.finish(.failure(Self.map(error))) }
            })
            receive()
        case .waiting(let error):
            // "Waiting" means the path is unusable right now (refused, unreachable, no DNS…).
            // A screen saver has no reason to wait around for it.
            finish(.failure(Self.map(error)))
        case .failed(let error):
            finish(.failure(Self.map(error)))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if self.finished { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            do {
                if self.head == nil {
                    self.head = try HTTPResponseParser.parseHead(self.buffer)
                }
                if let head = self.head,
                   let response = try HTTPResponseParser.finish(
                       head: head, data: self.buffer, atEOF: isComplete, isHeadRequest: self.isHeadRequest) {
                    self.finish(.success(response))
                    return
                }
            } catch {
                self.finish(.failure(error))
                return
            }
            if let error {
                self.finish(.failure(Self.map(error)))
            } else if isComplete {
                self.finish(.failure(HTTPError.malformedResponse))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    static func map(_ error: NWError) -> HTTPError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ETIMEDOUT: return .timedOut
            case .EHOSTUNREACH, .EHOSTDOWN: return .connectionFailed("host unreachable")
            case .ENETUNREACH, .ENETDOWN: return .connectionFailed("network unreachable")
            case .ECONNRESET: return .connectionFailed("connection reset")
            case .ECANCELED: return .cancelled
            default: return .connectionFailed(error.localizedDescription)
            }
        case .dns:
            return .hostNotFound
        case .tls:
            return .certificateRejected
        @unknown default:
            return .connectionFailed(error.localizedDescription)
        }
    }
}

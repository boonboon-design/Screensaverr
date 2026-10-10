import Network
import XCTest
@testable import ScreensaverrCore

/// A tiny loopback server that answers every connection with a canned response.
private final class CannedServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CannedServer")
    private let lock = NSLock()
    private var _requests: [String] = []
    private var held: [NWConnection] = []
    let port: UInt16

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// `respond` gets the raw request head and returns the bytes to send back before closing,
    /// or nil to keep the connection open without answering.
    init(respond: @escaping (String) -> [Data]?) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        let queue = self.queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.readRequest(connection, buffer: Data(), respond: respond)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private func readRequest(_ connection: NWConnection, buffer: Data, respond: @escaping (String) -> [Data]?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.lock.lock(); self._requests.append(head); self.lock.unlock()
                if let pieces = respond(head) {
                    self.send(pieces, on: connection)
                } else {
                    self.held.append(connection)
                }
            } else if error == nil {
                self.readRequest(connection, buffer: buffer, respond: respond)
            }
        }
    }

    private func send(_ pieces: [Data], on connection: NWConnection) {
        guard let first = pieces.first else {
            connection.cancel()
            return
        }
        connection.send(content: first, completion: .contentProcessed { [weak self] _ in
            // Small pause between pieces so the client sees them as separate reads.
            self?.queue.asyncAfter(deadline: .now() + 0.02) {
                self?.send(Array(pieces.dropFirst()), on: connection)
            }
        })
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in held { connection.cancel() }
            held = []
        }
    }
}

final class PlainHTTPTransportTests: XCTestCase {
    func testContentLengthResponseAndHeaders() async throws {
        let server = try CannedServer { _ in
            [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"version\":\"4\"}".utf8)]
        }
        defer { server.stop() }

        var request = HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/v3/system/status?x=1")!)
        request.headers["X-Api-Key"] = "secret"
        let response = try await PlainHTTPTransport().perform(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "{\"version\":\"4\"}")
        let head = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(head.hasPrefix("GET /api/v3/system/status?x=1 HTTP/1.1"), head)
        XCTAssertTrue(head.contains("X-Api-Key: secret"), head)
    }

    func testChunkedResponseSplitAcrossPackets() async throws {
        let server = try CannedServer { _ in
            [
                Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8),
                Data("6\r\nHello,\r\n".utf8),
                Data("6\r\n world\r\n".utf8),
                Data("0\r\n\r\n".utf8),
            ]
        }
        defer { server.stop() }

        let response = try await PlainHTTPTransport().perform(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "Hello, world")
    }

    func testBodyUntilConnectionClose() async throws {
        let server = try CannedServer { _ in
            [Data("HTTP/1.0 200 OK\r\n\r\n".utf8), Data("part one, ".utf8), Data("part two".utf8)]
        }
        defer { server.stop() }

        let response = try await PlainHTTPTransport().perform(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "part one, part two")
    }

    func testFollowsRedirectsThroughHTTPClient() async throws {
        let server = try CannedServer { head in
            if head.hasPrefix("GET /old ") {
                return [Data("HTTP/1.1 301 Moved\r\nLocation: /new\r\nContent-Length: 0\r\n\r\n".utf8)]
            }
            return [Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew".utf8)]
        }
        defer { server.stop() }

        let response = try await HTTPClient().perform(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/old")!))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "new")
    }

    func testConnectionRefused() async throws {
        // Grab a free port, then close it so nothing is listening there.
        let server = try CannedServer { _ in [] }
        let port = server.port
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await PlainHTTPTransport().perform(HTTPRequest(url: URL(string: "http://127.0.0.1:\(port)/")!, timeout: 5))
            XCTFail("Expected an error")
        } catch let error as HTTPError {
            switch error {
            case .connectionRefused, .connectionFailed: break
            default: XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testTimeout() async throws {
        // A server that accepts the request but never answers.
        let server = try CannedServer { _ in nil }
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await PlainHTTPTransport().perform(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 1))
            XCTFail("Expected a timeout")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

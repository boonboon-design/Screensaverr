import XCTest
@testable import ScreensaverrCore

final class HTTPResponseParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testContentLengthBody() throws {
        let raw = data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\": true}\n")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.header("content-type"), "application/json")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "{\"ok\": true}\n")
    }

    func testIncompleteUntilAllBytesArrive() throws {
        let full = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789"
        XCTAssertNil(try HTTPResponseParser.parse(data(String(full.prefix(20))), atEOF: false))
        XCTAssertNil(try HTTPResponseParser.parse(data(String(full.dropLast(3))), atEOF: false))
        XCTAssertThrowsError(try HTTPResponseParser.parse(data(String(full.dropLast(3))), atEOF: true))
        XCTAssertNotNil(try HTTPResponseParser.parse(data(full), atEOF: false))
    }

    func testChunkedBody() throws {
        let raw = data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n7;ext=1\r\n, world\r\n0\r\n\r\n")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "Hello, world")
    }

    func testChunkedWithTrailersCompletesAtEOF() throws {
        let raw = data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Trailer: 1\r\n\r\n")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: true))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "abc")
    }

    func testChunkedIncomplete() throws {
        let raw = data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHel")
        XCTAssertNil(try HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertThrowsError(try HTTPResponseParser.parse(raw, atEOF: true))
    }

    func testChunkedUppercaseHexSize() throws {
        let body = String(repeating: "x", count: 26)
        let raw = data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1A\r\n\(body)\r\n0\r\n\r\n")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertEqual(response.body.count, 26)
    }

    func testReadUntilClose() throws {
        let raw = data("HTTP/1.0 200 OK\r\nServer: test\r\n\r\nstreamed body")
        XCTAssertNil(try HTTPResponseParser.parse(raw, atEOF: false))
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: true))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "streamed body")
    }

    func testSkipsInterimResponses() throws {
        let raw = data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\nno")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "no")
    }

    func testNoBodyStatuses() throws {
        let raw = data("HTTP/1.1 204 No Content\r\nX: y\r\n\r\n")
        let response = try XCTUnwrap(HTTPResponseParser.parse(raw, atEOF: false))
        XCTAssertEqual(response.statusCode, 204)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try HTTPResponseParser.parse(data("SSH-2.0-OpenSSH\r\n\r\n"), atEOF: false))
        XCTAssertThrowsError(try HTTPResponseParser.parse(data("garbage"), atEOF: true))
    }

    func testWorksOnSlicedData() throws {
        // Data slices keep their parent's indices; the parser must not assume 0-based indices.
        let padded = data("JUNKHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
        let slice = padded[padded.index(padded.startIndex, offsetBy: 4)...]
        let response = try XCTUnwrap(HTTPResponseParser.parse(slice, atEOF: false))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hi")
    }

    func testRequestSerialization() {
        var request = HTTPRequest(url: URL(string: "http://10.0.0.2:8989/sonarr/api/v3/calendar?start=2026-10-10T00:00:00Z&unmonitored=false")!)
        request.headers["X-Api-Key"] = "abc123"
        let text = String(decoding: PlainHTTPTransport.serialize(request, host: "10.0.0.2", port: 8989, defaultPort: 80), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /sonarr/api/v3/calendar?start=2026-10-10T00:00:00Z&unmonitored=false HTTP/1.1\r\n"), text)
        XCTAssertTrue(text.contains("\r\nHost: 10.0.0.2:8989\r\n"))
        XCTAssertTrue(text.contains("\r\nX-Api-Key: abc123\r\n"))
        XCTAssertTrue(text.contains("\r\nConnection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testRequestSerializationStripsHeaderInjection() {
        var request = HTTPRequest(url: URL(string: "http://example.com/")!)
        request.headers["X-Api-Key"] = "abc\r\nEvil: 1"
        let text = String(decoding: PlainHTTPTransport.serialize(request, host: "example.com", port: 80, defaultPort: 80), as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nEvil: 1\r\n"))
        XCTAssertTrue(text.contains("\r\nHost: example.com\r\n"))
    }
}

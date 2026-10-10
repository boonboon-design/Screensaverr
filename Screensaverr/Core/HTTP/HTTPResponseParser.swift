import Foundation

/// Status line + headers of an HTTP/1.x response, plus where the body starts in the buffer.
struct HTTPResponseHead: Equatable {
    var statusCode: Int
    var headers: [String: String]
    /// Offset (from the buffer's start) of the first body byte.
    var bodyOffset: Int

    var isChunked: Bool {
        headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
    }

    var contentLength: Int? {
        headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// A small, incremental HTTP/1.1 response parser used by `PlainHTTPTransport`.
///
/// It supports `Content-Length`, `Transfer-Encoding: chunked` and read-until-close bodies,
/// and skips interim `1xx` responses.
enum HTTPResponseParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    /// Parses the head, or returns nil if more bytes are needed.
    static func parseHead(_ data: Data) throws -> HTTPResponseHead? {
        var searchStart = data.startIndex
        while true {
            guard let end = data.range(of: headerTerminator, in: searchStart..<data.endIndex) else {
                return nil
            }
            let headerBytes = data[searchStart..<end.lowerBound]
            let text = String(data: headerBytes, encoding: .utf8)
                ?? String(data: headerBytes, encoding: .isoLatin1)
                ?? ""
            var lines = text.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { throw HTTPError.malformedResponse }
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
                throw HTTPError.malformedResponse
            }

            // Interim response (e.g. "100 Continue"): skip it and parse the next head.
            if (100..<200).contains(code) && code != 101 {
                searchStart = end.upperBound
                continue
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let existing = headers[name] {
                    headers[name] = existing + ", " + value
                } else {
                    headers[name] = value
                }
            }
            return HTTPResponseHead(
                statusCode: code,
                headers: headers,
                bodyOffset: data.distance(from: data.startIndex, to: end.upperBound)
            )
        }
    }

    /// Returns the full response once the body is complete, nil if more bytes are needed.
    /// Throws when the data can never become a valid response (e.g. truncated at EOF).
    static func parse(_ data: Data, atEOF: Bool, isHeadRequest: Bool = false) throws -> HTTPResponse? {
        guard let head = try parseHead(data) else {
            if atEOF { throw HTTPError.malformedResponse }
            return nil
        }
        return try finish(head: head, data: data, atEOF: atEOF, isHeadRequest: isHeadRequest)
    }

    /// Like `parse`, but reuses an already-parsed head.
    static func finish(
        head: HTTPResponseHead,
        data: Data,
        atEOF: Bool,
        isHeadRequest: Bool = false
    ) throws -> HTTPResponse? {
        let bodyStart = data.index(data.startIndex, offsetBy: head.bodyOffset)
        let body = data[bodyStart..<data.endIndex]

        func response(_ bytes: Data) -> HTTPResponse {
            HTTPResponse(statusCode: head.statusCode, headers: head.headers, body: Data(bytes))
        }

        if isHeadRequest || head.statusCode == 204 || head.statusCode == 304 {
            return response(Data())
        }

        if head.isChunked {
            // Cheap check first so we don't re-decode on every packet.
            if !atEOF && !body.isEmpty && !endsLikeChunkedTerminator(body) {
                return nil
            }
            if let decoded = try decodeChunked(body) {
                return response(decoded)
            }
            if atEOF { throw HTTPError.malformedResponse }
            return nil
        }

        if let length = head.contentLength {
            if body.count >= length {
                return response(body.prefix(length))
            }
            if atEOF { throw HTTPError.malformedResponse }
            return nil
        }

        // No framing information: the body runs until the server closes the connection.
        return atEOF ? response(body) : nil
    }

    private static func endsLikeChunkedTerminator(_ body: Data) -> Bool {
        // "0\r\n\r\n" with no trailers is by far the most common ending.
        let terminator = Data("0\r\n\r\n".utf8)
        guard body.count >= terminator.count else { return false }
        return body.suffix(terminator.count) == terminator
    }

    /// Decodes a chunked body. Returns nil if the terminating chunk hasn't arrived yet.
    static func decodeChunked(_ data: Data) throws -> Data? {
        var output = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeField = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeField, radix: 16), size >= 0 else {
                throw HTTPError.malformedResponse
            }
            index = lineEnd.upperBound

            if size == 0 {
                // Optional trailer headers, then an empty line.
                while true {
                    guard let end = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
                    if end.lowerBound == index { return output }
                    index = end.upperBound
                }
            }

            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(index, offsetBy: size)
            output.append(data[index..<chunkEnd])
            let afterChunk = data.index(chunkEnd, offsetBy: 2)
            guard data[chunkEnd..<afterChunk] == crlf else { throw HTTPError.malformedResponse }
            index = afterChunk
        }
    }
}

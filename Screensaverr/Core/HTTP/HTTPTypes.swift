import Foundation

struct HTTPRequest {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var timeout: TimeInterval = 15
}

struct HTTPResponse {
    var statusCode: Int
    /// Header names are lower-cased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// A short, printable excerpt of the body for error messages.
    var bodySnippet: String {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTPError: Error, LocalizedError, Equatable {
    case invalidURL
    case timedOut
    case hostNotFound
    case connectionRefused
    case connectionFailed(String)
    case certificateRejected
    case malformedResponse
    case tooManyRedirects
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The URL isn't valid."
        case .timedOut: return "The server didn't respond in time."
        case .hostNotFound: return "Couldn't find that host. Check the address."
        case .connectionRefused: return "Connection refused. Check the address and port."
        case .connectionFailed(let detail): return "Couldn't connect (\(detail))."
        case .certificateRejected:
            return "The HTTPS certificate isn't trusted. Turn on \u{201C}Allow self-signed certificates\u{201D} if you use one."
        case .malformedResponse: return "The server sent a response that couldn't be read."
        case .tooManyRedirects: return "Too many redirects."
        case .cancelled: return "Cancelled."
        }
    }
}

protocol HTTPTransport: AnyObject {
    func perform(_ request: HTTPRequest) async throws -> HTTPResponse
}

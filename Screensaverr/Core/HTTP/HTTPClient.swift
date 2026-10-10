import Foundation

/// Routes `http://` to the raw-socket transport and `https://` to URLSession,
/// and follows redirects for the former.
final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    private let plain: HTTPTransport
    private let secure: URLSessionTransport

    init(plain: HTTPTransport = PlainHTTPTransport(), secure: URLSessionTransport = URLSessionTransport()) {
        self.plain = plain
        self.secure = secure
    }

    var allowInvalidCertificates: Bool {
        get { secure.allowInvalidCertificates }
        set { secure.allowInvalidCertificates = newValue }
    }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var current = request
        for _ in 0..<6 {
            let isHTTPS = current.url.scheme?.lowercased() == "https"
            let transport: HTTPTransport = isHTTPS ? secure : plain
            let response = try await transport.perform(current)
            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.header("location"),
               let next = URL(string: location, relativeTo: current.url)?.absoluteURL {
                current.url = next
                if response.statusCode == 303 { current.method = "GET" }
                continue
            }
            return response
        }
        throw HTTPError.tooManyRedirects
    }
}

/// Errors surfaced to the user, phrased for humans.
enum ServiceError: Error, LocalizedError {
    case notConfigured
    case unauthorized(Int)
    case notFound
    case httpStatus(Int)
    case unexpectedResponse(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a URL and API key in Options."
        case .unauthorized(let code):
            return "The API key was rejected (HTTP \(code))."
        case .notFound:
            return "Not found (HTTP 404). Check the URL, including any URL base such as /sonarr."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .unexpectedResponse(let detail):
            return detail
        case .server(let message):
            return message
        }
    }

    /// A short, user-presentable description for any error.
    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return error.localizedDescription
    }
}

/// Shared plumbing for the four API clients.
struct APIRequester {
    let config: ServiceConfig
    let http: HTTPClient
    /// Send the key as an `X-Api-Key` header (the *arr apps and Seerr).
    var sendsKeyHeader = true
    var timeout: TimeInterval = 15

    func get(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> HTTPResponse {
        guard let url = config.endpoint(path, query: query) else { throw ServiceError.notConfigured }
        var request = HTTPRequest(url: url, timeout: timeout)
        if authenticated && sendsKeyHeader {
            request.headers["X-Api-Key"] = config.trimmedAPIKey
        }
        let response = try await http.perform(request)
        switch response.statusCode {
        case 200..<300: return response
        case 401, 403: throw ServiceError.unauthorized(response.statusCode)
        case 404: throw ServiceError.notFound
        default: throw ServiceError.httpStatus(response.statusCode)
        }
    }

    func getJSON<T: Decodable>(
        _ type: T.Type,
        _ path: String,
        query: [URLQueryItem] = [],
        authenticated: Bool = true,
        serviceName: String
    ) async throws -> T {
        let response = try await get(path, query: query, authenticated: authenticated)
        return try JSONSupport.decode(type, from: response, serviceName: serviceName)
    }
}

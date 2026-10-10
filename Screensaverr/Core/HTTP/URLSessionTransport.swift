import Foundation

/// HTTPS requests go through URLSession (TLS, HTTP/2, proxies, redirects for free).
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _allowInvalidCertificates = false
    private var session: URLSession!

    /// Accept self-signed / otherwise untrusted server certificates.
    var allowInvalidCertificates: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowInvalidCertificates }
        set { lock.lock(); _allowInvalidCertificates = newValue; lock.unlock() }
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": PlainHTTPTransport.userAgent]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.malformedResponse }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           allowInvalidCertificates,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func map(_ error: URLError) -> HTTPError {
        switch error.code {
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .hostNotFound
        case .cannotConnectToHost: return .connectionRefused
        case .cancelled: return .cancelled
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return .certificateRejected
        case .badServerResponse, .cannotParseResponse: return .malformedResponse
        case .httpTooManyRedirects: return .tooManyRedirects
        default: return .connectionFailed(error.localizedDescription)
        }
    }
}

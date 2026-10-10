import Foundation

enum JSONSupport {
    static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse, serviceName: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            let snippet = response.bodySnippet.lowercased()
            if snippet.hasPrefix("<!doctype") || snippet.hasPrefix("<html") || snippet.hasPrefix("<?xml") {
                throw ServiceError.unexpectedResponse(
                    "Got a web page instead of \(serviceName) API data. Check the URL (and URL base)."
                )
            }
            throw ServiceError.unexpectedResponse("Couldn't read the response from \(serviceName).")
        }
    }

    // MARK: Dates

    private static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let internetDateTimeFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parses the ISO-8601 flavours the services emit:
    /// `2026-10-12T01:00:00Z`, `2026-10-09T12:34:56.123Z`, `2026-10-12T01:00:00+02:00`, `2026-10-12`.
    static func parseDate(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = internetDateTime.date(from: text) ?? internetDateTimeFractional.date(from: text) {
            return date
        }
        // .NET sometimes emits 7 fractional digits; trim to milliseconds and retry.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone]
            if fraction.count > 3 {
                text = String(text[..<dot]) + "." + fraction.prefix(3) + String(text[zone...])
                if let date = internetDateTimeFractional.date(from: text) { return date }
            }
        }
        // No zone designator: treat as UTC.
        if text.count == 19, let date = internetDateTime.date(from: text + "Z") { return date }
        if text.count == 10 { return dateOnly.date(from: text) }
        return nil
    }
}

/// Decodes an array, silently dropping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(_ elements: [Element] = []) { self.elements = elements }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                // Advance past the bad element.
                _ = try? container.decode(SkippedValue.self)
            }
        }
        elements = result
    }

    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// A number that may arrive as a JSON number or as a string (SABnzbd does both).
struct FlexibleDouble: Decodable, Equatable {
    var value: Double?

    init(_ value: Double?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces))
        } else if let flag = try? container.decode(Bool.self) {
            value = flag ? 1 : 0
        } else {
            value = nil
        }
    }
}

/// A boolean that may arrive as true/false, 0/1 or "True"/"false".
struct FlexibleBool: Decodable, Equatable {
    var value: Bool?

    init(_ value: Bool?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let number = try? container.decode(Double.self) {
            value = number != 0
        } else if let text = try? container.decode(String.self) {
            switch text.lowercased() {
            case "true", "1", "yes": value = true
            case "false", "0", "no": value = false
            default: value = nil
            }
        } else {
            value = nil
        }
    }
}

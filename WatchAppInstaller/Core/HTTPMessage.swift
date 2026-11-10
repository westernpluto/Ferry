import Foundation

/// Minimal HTTP/1.1 request parsing for the local install server.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]

    static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Parses the request head (everything up to the blank line). Returns nil if it is malformed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: headerTerminator),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers)
    }
}

/// A single `Range: bytes=…` request, resolved against a resource size.
struct ByteRange: Equatable {
    var lowerBound: Int64
    var upperBound: Int64  // inclusive

    var length: Int64 { upperBound - lowerBound + 1 }

    /// Returns nil when the header is absent/unsupported (serve the whole file),
    /// or `.some(nil)` when it is unsatisfiable.
    static func parse(_ header: String?, resourceSize size: Int64) -> ByteRange?? {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0, size > 0 else { return .some(nil) }
            return .some(ByteRange(lowerBound: max(0, size - suffix), upperBound: size - 1))
        }
        guard let start = Int64(startText), start < size else { return .some(nil) }
        var end = size - 1
        if !endText.isEmpty {
            guard let parsed = Int64(endText), parsed >= start else { return .some(nil) }
            end = min(parsed, size - 1)
        }
        return .some(ByteRange(lowerBound: start, upperBound: end))
    }
}

enum HTTPResponseHead {
    static func make(status: Int, reason: String, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

import Foundation

/// HTTP/1.1 and RTSP/1.0 messages as AirPlay uses them: a start line, headers, and a body
/// sized by Content-Length.
struct HTTPRequest: Sendable {
    var method: String
    var uri: String
    var version: String
    /// In the order they're written.
    var headers: [(name: String, value: String)]
    var body: Data

    func encoded() -> Data {
        var text = "\(method) \(uri) \(version)\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + body
    }
}

struct HTTPMessage: Sendable {
    /// For a response: "RTSP/1.0", "200", "OK". For a request: "POST", "/command", "RTSP/1.0".
    let startLine: [String]
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    var statusCode: Int? { startLine.count > 1 ? Int(startLine[1]) : nil }

    /// Takes one whole message off the front of `buffer`, if there is one.
    static func next(from buffer: inout Data) -> HTTPMessage? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        buffer = Data(buffer[buffer.index(bodyStart, offsetBy: length)...])
        return HTTPMessage(startLine: startLine, headers: headers, body: body)
    }
}

import Foundation
import Network

/// The subset of an HTTP request consumed by the local control API.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: [String: Any]

    /// Returns nil until a request header and its declared body are available.
    /// The server handles one request per connection, so trailing bytes are ignored.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
            let header = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        let length = contentLength(in: lines.dropFirst())
        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let bodyData = data[bodyStart..<(bodyStart + length)]
        // Non-object or invalid JSON has historically been treated as an empty body.
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            // Repeated keys use the last value; a key without '=' has an empty value.
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(
            method: String(requestLine[0]), path: components?.path ?? target, query: query, body: body)
    }

    private static func contentLength(in headerLines: ArraySlice<String>) -> Int {
        var length = 0
        for line in headerLines {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                length = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return length
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }

    /// Encodes exactly one response. The transport closes the connection after sending it.
    var serialized: Data {
        var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        header += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        return Data(header.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// A tiny HTTP/1.1 server on localhost. One request per connection.
/// Request/response values above handle encoding independently of the listener.
final class HTTPServer {
    private let port: NWEndpoint.Port
    private let handler: (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "iphone-use.http", attributes: .concurrent)

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in log("http \(state)") }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                let response = self.handler(request)
                self.send(response, on: connection)
            } else if done || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}

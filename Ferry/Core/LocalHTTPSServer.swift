import Foundation
import Network
import Security

/// A small HTTPS server, bound to the loopback interface, that serves the
/// install manifest and IPA to iOS's installer daemon.
///
/// `itms-services` only accepts HTTPS URLs with a certificate the device trusts,
/// so the server presents a TLS identity whose root CA the user has installed
/// and trusted (see `scripts/make-local-cert.sh`).
final class LocalHTTPSServer {
    enum Source {
        case data(Data)
        case file(URL)
    }

    struct Route {
        var contentType: String
        var source: Source
    }

    enum Event {
        case ready(UInt16)
        case stopped
        case failed(String)
        case request(method: String, path: String, status: Int)
        case transfer(path: String, sent: Int64, total: Int64)
        case transferFinished(path: String)
        /// A client connected but the connection failed, e.g. during the TLS handshake.
        case connectionFailed(String)
        /// The listener can't accept connections yet (for example, the port is busy).
        case waiting(String)
    }

    enum ServerError: LocalizedError {
        case invalidIdentity
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The TLS identity could not be used."
            case .invalidPort: return "The port number is not valid."
            }
        }
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "LocalHTTPSServer")
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var connections: [ObjectIdentifier: ConnectionHandler] = [:]

    private(set) var port: UInt16 = 0
    var isRunning: Bool { listener != nil }

    func setRoute(_ path: String, _ route: Route) {
        queue.async { self.routes[path] = route }
    }

    func removeAllRoutes() {
        queue.async { self.routes.removeAll() }
    }

    /// Starts listening on the loopback interface. With `identity` nil it serves plain HTTP,
    /// which is only used to hand the root-certificate profile to Safari.
    func start(identity: SecIdentity?, port: UInt16) throws {
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ServerError.invalidPort }

        let parameters: NWParameters
        if let identity {
            guard let secIdentity = sec_identity_create(identity) else { throw ServerError.invalidIdentity }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        // Only this device can connect: bind to the loopback interface (127.0.0.1 / ::1).
        // (`acceptLocalOnly` means "local network", which doesn't reliably include loopback.)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.emit(.ready(port))
            case .failed(let error):
                self?.emit(.failed(error.localizedDescription))
                DispatchQueue.main.async { self?.stop() }
            case .cancelled:
                self?.emit(.stopped)
            case .waiting(let error):
                self?.emit(.waiting(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.port = port
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection, queue: queue)
        let key = ObjectIdentifier(handler)
        connections[key] = handler
        handler.routeLookup = { [weak self] path in self?.routes[path] }
        handler.onEvent = { [weak self] event in self?.emit(event) }
        handler.onClose = { [weak self] in self?.connections[key] = nil }
        handler.start()
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

/// Handles one request on one connection, then closes it.
private final class ConnectionHandler {
    private static let chunkSize = 256 * 1024
    private static let maxHeaderSize = 64 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    var routeLookup: ((String) -> LocalHTTPSServer.Route?)?
    var onEvent: ((LocalHTTPSServer.Event) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.onEvent?(.connectionFailed(Self.describe(error)))
                self?.finish()
            case .waiting(let error):
                self?.onEvent?(.connectionFailed(Self.describe(error)))
                self?.connection.cancel()
            case .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            return "secure connection failed (TLS \(status)): the client didn't accept the certificate"
        default:
            return error.localizedDescription
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if let request = HTTPRequest.parse(self.buffer) {
                self.respond(to: request)
            } else if error != nil || isComplete || self.buffer.count > Self.maxHeaderSize {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func respond(to request: HTTPRequest) {
        guard request.method == "GET" || request.method == "HEAD" else {
            sendSimple(status: 405, reason: "Method Not Allowed", request: request)
            return
        }
        guard let route = routeLookup?(request.path) else {
            sendSimple(status: 404, reason: "Not Found", request: request)
            return
        }

        switch route.source {
        case .data(let data):
            var headers = baseHeaders(contentType: route.contentType)
            headers.append(("Content-Length", "\(data.count)"))
            onEvent?(.request(method: request.method, path: request.path, status: 200))
            let head = HTTPResponseHead.make(status: 200, reason: "OK", headers: headers)
            send(request.method == "HEAD" ? head : head + data, thenClose: true)

        case .file(let url):
            serveFile(url, contentType: route.contentType, request: request)
        }
    }

    private func serveFile(_ url: URL, contentType: String, request: HTTPRequest) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            sendSimple(status: 500, reason: "Internal Server Error", request: request)
            return
        }

        var status = 200
        var reason = "OK"
        var range = ByteRange(lowerBound: 0, upperBound: max(0, size - 1))
        var headers = baseHeaders(contentType: contentType)
        headers.append(("Accept-Ranges", "bytes"))

        switch ByteRange.parse(request.headers["range"], resourceSize: size) {
        case .none:
            break
        case .some(.none):
            try? handle.close()
            headers.append(("Content-Range", "bytes */\(size)"))
            headers.append(("Content-Length", "0"))
            onEvent?(.request(method: request.method, path: request.path, status: 416))
            send(HTTPResponseHead.make(status: 416, reason: "Range Not Satisfiable", headers: headers), thenClose: true)
            return
        case .some(.some(let requested)):
            range = requested
            status = 206
            reason = "Partial Content"
            headers.append(("Content-Range", "bytes \(requested.lowerBound)-\(requested.upperBound)/\(size)"))
        }

        let length = size == 0 ? 0 : range.length
        headers.append(("Content-Length", "\(length)"))
        onEvent?(.request(method: request.method, path: request.path, status: status))

        let head = HTTPResponseHead.make(status: status, reason: reason, headers: headers)
        guard request.method == "GET", length > 0 else {
            try? handle.close()
            send(head, thenClose: true)
            return
        }

        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
        } catch {
            try? handle.close()
            connection.cancel()
            return
        }

        send(head, thenClose: false) { [weak self] in
            self?.streamChunks(handle: handle, remaining: length, sent: 0, total: length, path: request.path)
        }
    }

    private func streamChunks(handle: FileHandle, remaining: Int64, sent: Int64, total: Int64, path: String) {
        guard remaining > 0 else {
            try? handle.close()
            onEvent?(.transferFinished(path: path))
            send(Data(), thenClose: true)
            return
        }
        let count = Int(min(Int64(Self.chunkSize), remaining))
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: count) ?? Data()
        } catch {
            chunk = Data()
        }
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        let newSent = sent + Int64(chunk.count)
        send(chunk, thenClose: false) { [weak self] in
            self?.onEvent?(.transfer(path: path, sent: newSent, total: total))
            self?.streamChunks(handle: handle, remaining: remaining - Int64(chunk.count), sent: newSent, total: total, path: path)
        }
    }

    private func sendSimple(status: Int, reason: String, request: HTTPRequest) {
        let body = Data("\(status) \(reason)\n".utf8)
        var headers = baseHeaders(contentType: "text/plain; charset=utf-8")
        headers.append(("Content-Length", "\(body.count)"))
        onEvent?(.request(method: request.method, path: request.path, status: status))
        let head = HTTPResponseHead.make(status: status, reason: reason, headers: headers)
        send(request.method == "HEAD" ? head : head + body, thenClose: true)
    }

    private func baseHeaders(contentType: String) -> [(String, String)] {
        [("Content-Type", contentType), ("Connection", "close"), ("Cache-Control", "no-store")]
    }

    private func send(_ data: Data, thenClose: Bool, completion: (() -> Void)? = nil) {
        connection.send(content: data.isEmpty ? nil : data, contentContext: .defaultMessage, isComplete: thenClose, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.connection.cancel()
                return
            }
            if thenClose {
                self.connection.cancel()
            } else {
                completion?()
            }
        })
    }
}

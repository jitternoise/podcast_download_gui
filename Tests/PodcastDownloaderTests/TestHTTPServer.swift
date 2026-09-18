import Foundation
import Network

/// A one-trick HTTP/1.1 server on 127.0.0.1 for download tests: serves one
/// body for every request, optionally lying about (or truncating to) a
/// different length so the client's checks can be exercised.
final class TestHTTPServer: @unchecked Sendable {
    struct Response {
        var body: Data
        var contentType = "audio/mpeg"
        /// Announced Content-Length; nil means the real body length.
        var announcedLength: Int? = nil
        /// Send only this many bytes before closing (simulates a dropped connection).
        var sendOnly: Int? = nil
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http")
    private let lock = NSLock()
    private var response: Response
    private(set) var requestCount = 0
    private(set) var port: UInt16 = 0

    init(response: Response) throws {
        self.response = response
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        let l = listener
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        ready.wait()
        port = l.port?.rawValue ?? 0
    }

    func url(path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func set(_ response: Response) { lock.withLock { self.response = response } }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let r = self.lock.withLock { self.requestCount += 1; return self.response }
            let range = request.range(of: "\r\nRange: bytes=") != nil
            // Keep it simple: no Range support, so a resumed download restarts.
            let length = r.announcedLength ?? r.body.count
            let status = range ? "200 OK" : "200 OK"
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
            _ = head.utf8
            let payload = r.sendOnly.map { r.body.prefix($0) } ?? r.body
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            head = ""
        }
    }
}

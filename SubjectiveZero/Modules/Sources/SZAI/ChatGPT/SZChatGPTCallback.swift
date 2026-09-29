// SPDX-License-Identifier: AGPL-3.0-only
// a short-lived browser callback listener bound exclusively to IPv4 loopback.
import Foundation
import Network

@MainActor
final class SZChatGPTCallback {
    enum Event: Sendable { case ready(URL), callback(URL) }
    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var redirect: URL?

    init() throws {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirect = url
                    self.continuation.yield(.ready(url))
                case .failed:
                    self.continuation.finish(throwing: SZChatGPTError("Could not start the sign-in callback. Please try again."))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                self.buffers[id] = Data()
                connection.start(queue: .main)
                self.receive(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        continuation.finish()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                if let data { self.buffers[id, default: Data()].append(data) }
                let buffer = self.buffers[id] ?? Data()
                guard buffer.count <= 16384, error == nil else { self.close(connection); return }
                if let header = String(data: buffer, encoding: .utf8), header.contains("\r\n\r\n") {
                    let line = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                    if line.count == 3, line[0] == "GET", let redirect = self.redirect,
                       let url = URL(string: String(line[1]), relativeTo: redirect)?.absoluteURL,
                       url.host == redirect.host, url.port == redirect.port, url.path == redirect.path {
                        self.continuation.yield(.callback(url))
                        self.respond(connection, status: "200 OK", text: Self.completionPage, html: true)
                    } else { self.respond(connection, status: "404 Not Found", text: "Not found.") }
                } else if done { self.close(connection) } else { self.receive(connection) }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, text: String, html: Bool = false) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(html ? "text/html" : "text/plain"); charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: \(text.utf8.count)\r\n\r\n\(text)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    static let completionPage = """
    <!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Return to SubZ</title>
    <style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:light-dark(#f6f6f6,#141414);color:light-dark(#171717,#fafafa)}
    main{max-width:400px;margin:24px;padding:44px;border:1px solid light-dark(#ddd,#333);border-radius:20px;background:light-dark(white,#1e1e1e)}
    small{font-weight:600;letter-spacing:.08em;color:light-dark(#666,#aaa)}
    h1{font-size:28px;letter-spacing:-.7px;margin:22px 0 16px}p{font-size:16px;line-height:1.6;color:light-dark(#555,#bbb)}
    </style><main><small>SUBZ + CHATGPT</small><h1>Return to SubZ</h1>
    <p>Your browser has handed sign-in back to SubZ. Finish connecting in the app.</p>
    <p>You can close this tab.</p></main>
    <script>history.replaceState(null,"","/auth/complete")</script></html>
    """

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections[ObjectIdentifier(connection)] = nil
        buffers[ObjectIdentifier(connection)] = nil
    }
}

//
//  LocalOverlayAPIServer.swift
//  aki-notch-ui
//
//  Created by Codex on 26/03/2026.
//

import Foundation
import Network

final class LocalOverlayAPIServer {
    static let shared = LocalOverlayAPIServer()

    private(set) var port: NWEndpoint.Port = 47037
    private let maxRequestSize = 1_048_576  // 1 MB
    private let connectionTimeoutSeconds: Double = 300  // 5 minutes

    private var listener: NWListener?
    private var onOverlay: (@MainActor (OverlayAPIRequest) -> Void)?
    private var onCollapse: (@MainActor () -> Void)?
    private var onClear: (@MainActor () -> Void)?
    private var onChat: (@MainActor (ChatAPIRequest, @escaping (String) -> Void) -> Void)?
    private var onListen: (@MainActor (@escaping (String) -> Void) -> Void)?
    private var onGame: (@MainActor (GameAPIRequest, @escaping (String) -> Void) -> Void)?
    private var onCharacters: (@MainActor () -> [[String: Any]])?

    /// Tracks pending timeout work items keyed by connection identity.
    private var timeoutItems: [ObjectIdentifier: DispatchWorkItem] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start(
        port: UInt16 = 47037,
        onOverlay: @escaping @MainActor (OverlayAPIRequest) -> Void,
        onCollapse: @escaping @MainActor () -> Void,
        onClear: @escaping @MainActor () -> Void,
        onChat: @escaping @MainActor (ChatAPIRequest, @escaping (String) -> Void) -> Void,
        onListen: @escaping @MainActor (@escaping (String) -> Void) -> Void,
        onGame: @escaping @MainActor (GameAPIRequest, @escaping (String) -> Void) -> Void,
        onCharacters: @escaping @MainActor () -> [[String: Any]]
    ) throws {
        guard listener == nil else {
            return
        }

        self.port = NWEndpoint.Port(rawValue: port) ?? 47037

        self.onOverlay = onOverlay
        self.onCollapse = onCollapse
        self.onClear = onClear
        self.onChat = onChat
        self.onListen = onListen
        self.onGame = onGame
        self.onCharacters = onCharacters

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: self.port)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil

        onOverlay = nil
        onCollapse = nil
        onClear = nil
        onChat = nil
        onListen = nil
        self.onGame = nil
        self.onCharacters = nil

        for (_, item) in timeoutItems {
            item.cancel()
        }
        timeoutItems.removeAll()
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, accumulatedData: Data(), cachedHeader: nil)
    }

    /// Cached result of finding the header/body boundary so we don't re‑parse
    /// the entire buffer on every incremental `receive` call.
    private struct HeaderInfo {
        let bodyStartOffset: Int
        let contentLength: Int
    }

    private func receive(
        on connection: NWConnection,
        accumulatedData: Data,
        cachedHeader: HeaderInfo?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.respond(
                    to: connection, status: "500 Internal Server Error",
                    body: "{\"error\":\"internal error\"}")
                _ = error  // suppress unused warning; we intentionally do not expose the message
                return
            }

            let nextData = accumulatedData + (data ?? Data())

            // Enforce request body size limit
            if nextData.count > self.maxRequestSize {
                self.respond(
                    to: connection, status: "413 Payload Too Large",
                    body: "{\"error\":\"request too large\"}")
                return
            }

            let result = self.isRequestComplete(nextData, cachedHeader: cachedHeader)

            if result.isComplete {
                if let response = self.route(requestData: nextData, connection: connection) {
                    self.respond(to: connection, status: response.status, body: response.body)
                } else {
                    // Connection is held open (e.g. /chat, /listen) — schedule a timeout.
                    self.scheduleTimeout(for: connection)
                }
                return
            }

            if isComplete {
                self.respond(
                    to: connection, status: "400 Bad Request",
                    body: "{\"error\":\"incomplete request\"}")
                return
            }

            self.receive(on: connection, accumulatedData: nextData, cachedHeader: result.headerInfo)
        }
    }

    // MARK: - Timeout management

    private func scheduleTimeout(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let workItem = DispatchWorkItem { [weak self] in
            self?.timeoutItems.removeValue(forKey: key)
            self?.respond(
                to: connection, status: "408 Request Timeout",
                body: "{\"error\":\"request timeout\"}")
        }
        timeoutItems[key] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + connectionTimeoutSeconds, execute: workItem)
    }

    private func cancelTimeout(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        timeoutItems.removeValue(forKey: key)?.cancel()
    }

    // MARK: - Routing

    private func route(requestData: Data, connection: NWConnection) -> (
        status: String, body: String
    )? {
        guard
            let requestString = String(data: requestData, encoding: .utf8),
            let headerRange = requestString.range(of: "\r\n\r\n")
        else {
            return ("400 Bad Request", "{\"error\":\"invalid request\"}")
        }

        let headersPart = String(requestString[..<headerRange.lowerBound])
        let bodyPart = String(requestString[headerRange.upperBound...])
        let headerLines = headersPart.components(separatedBy: "\r\n")

        guard let requestLine = headerLines.first else {
            return ("400 Bad Request", "{\"error\":\"missing request line\"}")
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return ("400 Bad Request", "{\"error\":\"malformed request line\"}")
        }

        let method = String(components[0])
        let path = String(components[1])

        // CORS preflight — respond to OPTIONS on any path
        if method == "OPTIONS" {
            return ("204 No Content", "")
        }

        switch (method, path) {
        case ("GET", "/health"):
            return (
                "200 OK",
                "{\"status\":\"ok\",\"port\":\(port.rawValue),\"games\":[\"tic_tac_toe\",\"snake\",\"hangman\"]}"
            )
        case ("POST", "/overlay"):
            return handleOverlay(body: bodyPart)
        case ("POST", "/chat"):
            return handleChat(body: bodyPart, connection: connection)
        case ("GET", "/listen"):
            return handleListen(connection: connection)
        case ("POST", "/collapse"):
            Task { @MainActor in
                self.onCollapse?()
            }
            return ("200 OK", "{\"status\":\"collapsed\"}")
        case ("POST", "/clear"):
            Task { @MainActor in
                self.onClear?()
            }
            return ("200 OK", "{\"status\":\"cleared\"}")
        case ("POST", "/game"):
            return handleGame(body: bodyPart, connection: connection)
        case ("GET", "/characters"):
            return handleCharacters()
        default:
            return ("404 Not Found", "{\"error\":\"unknown route\"}")
        }
    }

    // MARK: - Route handlers

    private func handleOverlay(body: String) -> (status: String, body: String) {
        guard let data = body.data(using: .utf8) else {
            return ("400 Bad Request", "{\"error\":\"body is not utf8\"}")
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let request = try decoder.decode(OverlayAPIRequest.self, from: data)

            Task { @MainActor in
                self.onOverlay?(request)
            }

            return ("200 OK", "{\"status\":\"updated\"}")
        } catch {
            return ("400 Bad Request", "{\"error\":\"invalid JSON body\"}")
        }
    }

    private func handleChat(body: String, connection: NWConnection) -> (
        status: String, body: String
    )? {
        guard let data = body.data(using: .utf8) else {
            return ("400 Bad Request", "{\"error\":\"body is not utf8\"}")
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let request = try decoder.decode(ChatAPIRequest.self, from: data)

            Task { @MainActor in
                self.onChat?(request) { [weak self] answer in
                    let responseDict: [String: Any] = ["status": "answered", "answer": answer]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
                        let responseBody = String(data: jsonData, encoding: .utf8)
                    {
                        self?.respond(to: connection, status: "200 OK", body: responseBody)
                    } else {
                        self?.respond(
                            to: connection, status: "500 Internal Server Error",
                            body: "{\"error\":\"encoding failed\"}")
                    }
                }
            }

            return nil  // Connection held open until user answers
        } catch {
            return ("400 Bad Request", "{\"error\":\"invalid JSON body\"}")
        }
    }

    private func handleListen(connection: NWConnection) -> (status: String, body: String)? {
        Task { @MainActor in
            self.onListen? { [weak self] message in
                let responseDict: [String: Any] = ["status": "received", "message": message]
                if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
                    let responseBody = String(data: jsonData, encoding: .utf8)
                {
                    self?.respond(to: connection, status: "200 OK", body: responseBody)
                } else {
                    self?.respond(
                        to: connection, status: "500 Internal Server Error",
                        body: "{\"error\":\"encoding failed\"}")
                }
            }
        }

        return nil  // Connection held open until user sends a message
    }

    private func handleGame(body: String, connection: NWConnection) -> (
        status: String, body: String
    )? {
        guard let data = body.data(using: .utf8) else {
            return ("400 Bad Request", "{\"error\":\"body is not utf8\"}")
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let request = try decoder.decode(GameAPIRequest.self, from: data)

            Task { @MainActor in
                self.onGame?(request) { [weak self] result in
                    let responseDict: [String: Any] = ["status": "completed", "result": result]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
                        let responseBody = String(data: jsonData, encoding: .utf8)
                    {
                        self?.respond(to: connection, status: "200 OK", body: responseBody)
                    } else {
                        self?.respond(
                            to: connection, status: "500 Internal Server Error",
                            body: "{\"error\":\"encoding failed\"}")
                    }
                }
            }

            return nil  // Connection held open until game ends
        } catch {
            return ("400 Bad Request", "{\"error\":\"invalid JSON body\"}")
        }
    }

    private func handleCharacters() -> (status: String, body: String) {
        guard let handler = onCharacters else {
            return ("500 Internal Server Error", "{\"error\":\"not configured\"}")
        }
        var result: [[String: Any]] = []
        DispatchQueue.main.sync {
            result = handler()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result),
            let body = String(data: data, encoding: .utf8)
        else {
            return ("500 Internal Server Error", "{\"error\":\"encoding failed\"}")
        }
        return ("200 OK", body)
    }

    // MARK: - Request completeness (optimised with cached header position)

    private func isRequestComplete(
        _ data: Data, cachedHeader: HeaderInfo?
    ) -> (isComplete: Bool, headerInfo: HeaderInfo?) {
        // Fast path: header boundary was already located on a prior call.
        if let info = cachedHeader {
            let bodyLength = data.count - info.bodyStartOffset
            return (bodyLength >= info.contentLength, info)
        }

        // Search for the \r\n\r\n boundary in raw bytes (avoids full UTF‑8
        // conversion of the entire buffer).
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let range = data.range(of: Data(separator)) else {
            return (false, nil)
        }

        let bodyStartOffset = range.upperBound

        // Extract Content‑Length from the header portion only.
        let headersData = data[data.startIndex..<range.lowerBound]
        let contentLength: Int
        if let headersString = String(data: headersData, encoding: .utf8) {
            contentLength =
                headersString
                .components(separatedBy: "\r\n")
                .compactMap { line -> Int? in
                    let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pieces.count == 2,
                        pieces[0].lowercased() == "content-length"
                    else {
                        return nil
                    }
                    return Int(pieces[1].trimmingCharacters(in: .whitespaces))
                }
                .first ?? 0
        } else {
            contentLength = 0
        }

        let info = HeaderInfo(bodyStartOffset: bodyStartOffset, contentLength: contentLength)
        let bodyLength = data.count - bodyStartOffset
        return (bodyLength >= contentLength, info)
    }

    // MARK: - Response

    private func respond(to connection: NWConnection, status: String, body: String) {
        // Cancel any pending timeout for this connection.
        cancelTimeout(for: connection)

        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        header += "Connection: close\r\n"
        // CORS — always present
        header += "Access-Control-Allow-Origin: *\r\n"
        // Extra preflight headers for OPTIONS 204 responses
        if status == "204 No Content" {
            header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            header += "Access-Control-Allow-Headers: Content-Type\r\n"
        }
        header += "\r\n"

        let payload = header + body

        connection.send(
            content: payload.data(using: .utf8),
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}

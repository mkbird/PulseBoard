import Darwin
import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let rawTarget: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

    func query(_ name: String) -> String? {
        queryItems[name]
    }
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let contentType: String
    let extraHeaders: [(String, String)]
    let body: Data

    static func json<T: Encodable>(_ statusCode: Int = 200, _ payload: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(payload)) ?? Data("{\"ok\":false,\"error\":\"JSON encoding failed\"}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            contentType: "application/json; charset=utf-8",
            extraHeaders: [],
            body: data
        )
    }

    static func jsonError(_ statusCode: Int = 400, _ message: String) -> HTTPResponse {
        struct ErrPayload: Encodable {
            let ok = false
            let error: String
        }
        return .json(statusCode, ErrPayload(error: message))
    }

    static func html(_ statusCode: Int = 200, _ data: Data) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            contentType: "text/html; charset=utf-8",
            extraHeaders: [],
            body: data
        )
    }

    static func download(filename: String, contentType: String, data: Data) -> HTTPResponse {
        let asciiFallback = filename.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0 != "\"" ? Character($0) : "_" }
        let safeASCII = String(asciiFallback)
        let encodedUTF8 = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? safeASCII
        let disposition = "attachment; filename=\"\(safeASCII)\"; filename*=UTF-8''\(encodedUTF8)"
        return HTTPResponse(
            statusCode: 200,
            contentType: contentType,
            extraHeaders: [("Content-Disposition", disposition)],
            body: data
        )
    }
}

final class LocalWebServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false
    private(set) var boundPort: Int = 0
    private let handler: RequestHandler

    init(handler: @escaping RequestHandler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Starts listening on 0.0.0.0, trying preferredPort first and up to 10 consecutive fallback ports.
    @discardableResult
    func start(preferredPort: Int = 8766) throws -> Int {
        stop()

        var chosenFD: Int32 = -1
        var chosenPort: Int = 0

        for candidatePort in preferredPort..<(preferredPort + 10) {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(candidatePort).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0, Darwin.listen(fd, 128) == 0 {
                chosenFD = fd
                chosenPort = candidatePort
                break
            }
            Darwin.close(fd)
        }

        guard chosenFD >= 0 else {
            throw NSError(
                domain: "LocalWebServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法绑定本地 Web 服务端口（\(preferredPort)~\(preferredPort + 9)）"]
            )
        }

        lock.lock()
        serverFD = chosenFD
        boundPort = chosenPort
        running = true
        lock.unlock()

        let acceptFD = chosenFD
        let reqHandler = self.handler
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.acceptLoop(serverFD: acceptFD, owner: self, handler: reqHandler)
        }

        return chosenPort
    }

    func stop() {
        lock.lock()
        let fd = serverFD
        serverFD = -1
        running = false
        boundPort = 0
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && serverFD >= 0
    }

    private static func acceptLoop(
        serverFD: Int32,
        owner: LocalWebServer?,
        handler: @escaping RequestHandler
    ) {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            if owner?.isRunning == false {
                Darwin.close(clientFD)
                break
            }

            var yes: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            Task.detached(priority: .userInitiated) {
                defer { Darwin.close(clientFD) }
                guard let request = Self.readHTTPRequest(fd: clientFD) else { return }
                if request.method == "OPTIONS" {
                    let preflight = HTTPResponse(statusCode: 204, contentType: "text/plain", extraHeaders: [], body: Data())
                    Self.writeHTTPResponse(fd: clientFD, response: preflight)
                    return
                }
                let response = await handler(request)
                Self.writeHTTPResponse(fd: clientFD, response: response)
            }
        }
    }

    private static func readHTTPRequest(fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 8_192)
        var headerEndRange: Range<Data.Index>?

        while buffer.count < 262_144 {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if let range = buffer.range(of: delimiter) {
                headerEndRange = range
                break
            }
        }

        guard let headerEndRange else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        let method = parts[0].uppercased()
        let rawTarget = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        let contentLength = max(0, min(headers["content-length"].flatMap(Int.init) ?? 0, 10_485_760))
        var body = buffer.subdata(in: headerEndRange.upperBound..<buffer.count)
        while body.count < contentLength {
            let remaining = min(chunk.count, contentLength - body.count)
            let n = Darwin.recv(fd, &chunk, remaining, 0)
            if n <= 0 { break }
            body.append(chunk, count: n)
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        let (path, queryItems) = parseTarget(rawTarget)

        return HTTPRequest(
            method: method,
            rawTarget: rawTarget,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    /// Parses an HTTP request target (`path?query`), properly decoding `application/x-www-form-urlencoded`
    /// query parameters where `+` represents a space (`0x20`) and `%2B` represents a literal `+`.
    static func parseTarget(_ rawTarget: String) -> (path: String, queryItems: [String: String]) {
        let normalized = rawTarget.hasPrefix("/") ? rawTarget : "/" + rawTarget
        let targetWithoutFragment = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = targetWithoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)

        let rawPath = String(pieces[0])
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath

        var queryItems: [String: String] = [:]
        if pieces.count > 1 {
            let rawQuery = String(pieces[1])
            for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawKey = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                let key = rawKey.removingPercentEncoding ?? rawKey
                guard !key.isEmpty else { continue }
                if kv.count > 1 {
                    let rawVal = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                    queryItems[key] = rawVal.removingPercentEncoding ?? rawVal
                } else {
                    queryItems[key] = ""
                }
            }
        }
        return (decodedPath, queryItems)
    }

    private static func writeHTTPResponse(fd: Int32, response: HTTPResponse) {
        let reason: String = switch response.statusCode {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "OK"
        }

        var headerLines = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type"
        ]
        for (k, v) in response.extraHeaders {
            headerLines.append("\(k): \(v)")
        }
        let headerString = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var fullData = Data(headerString.utf8)
        fullData.append(response.body)

        fullData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var totalSent = 0
            let totalCount = rawBuf.count
            while totalSent < totalCount {
                let ptr = base.advanced(by: totalSent)
                let sent = Darwin.send(fd, ptr, totalCount - totalSent, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                totalSent += sent
            }
        }
    }
}

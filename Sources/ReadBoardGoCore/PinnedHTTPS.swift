import CryptoKit
import Foundation
import Network
import ReadBoardRemote
import Security

public enum PinnedHTTPS {
    @available(*, deprecated,
               message: "Use client(baseURL:certificateFingerprint:) so origin and transport errors remain typed.")
    public static func session(certificateFingerprint: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let delegate = PinnedCertificateDelegate(
            expectedFingerprint: certificateFingerprint,
            allowedOrigin: nil)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public static func client(baseURL: URL,
                              certificateFingerprint: String) -> PinnedHTTPSClient {
        PinnedHTTPSClient(baseURL: baseURL,
                          certificateFingerprint: certificateFingerprint)
    }

    public static func inspectCertificate(at baseURL: URL) async throws -> String {
        try await TLSCertificateProbe().inspect(baseURL: baseURL)
    }

    static func fingerprint(trust: SecTrust) -> String? {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }

    /// Certificate pinning is the server identity check. Once the exact leaf
    /// fingerprint matches, build a fresh trust object that evaluates that leaf
    /// as the only trust anchor with a basic X.509 policy. Reusing the trust
    /// supplied by URLSession is not sufficient on older macOS releases because
    /// that object was created with an SSL hostname policy and may retain the
    /// original policy context even after it is mutated. A fresh trust removes
    /// only hostname validation while preserving certificate date validation.
    /// The exact SHA-256 leaf fingerprint, rather than the self-signature of an
    /// explicitly trusted self-signed anchor, is the server identity proof.
    static func credential(
        for trust: SecTrust,
        expectedFingerprint: String
    ) -> Result<URLCredential, ReadBoardGoConnectionError> {
        switch pinnedTrust(for: trust, expectedFingerprint: expectedFingerprint) {
        case .success(let pinnedTrust):
            return .success(URLCredential(trust: pinnedTrust))
        case .failure(let error):
            return .failure(error)
        }
    }

    static func pinnedTrust(
        for trust: SecTrust,
        expectedFingerprint: String
    ) -> Result<SecTrust, ReadBoardGoConnectionError> {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first,
              let fingerprint = fingerprint(trust: trust) else {
            return .failure(.certificateUnavailable)
        }
        guard normalized(fingerprint) == normalized(expectedFingerprint) else {
            return .failure(.certificateNotTrusted)
        }

        var pinnedTrust: SecTrust?
        let trustStatus = SecTrustCreateWithCertificates(
            leaf,
            SecPolicyCreateBasicX509(),
            &pinnedTrust)
        guard trustStatus == errSecSuccess, let pinnedTrust else {
            return .failure(.certificateUnavailable)
        }
        let anchorStatus = SecTrustSetAnchorCertificates(pinnedTrust, [leaf] as CFArray)
        guard anchorStatus == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(pinnedTrust, true) == errSecSuccess else {
            return .failure(.certificateUnavailable)
        }
        var evaluationError: CFError?
        guard SecTrustEvaluateWithError(pinnedTrust, &evaluationError) else {
            return .failure(.certificateNotTrusted)
        }
        return .success(pinnedTrust)
    }

    /// Certificate inspection intentionally cancels the unauthenticated probe
    /// after observing server trust. URLSession may report that cancellation
    /// before the challenge callback resumes its continuation, so the observed
    /// fingerprint is the authority for that completion ordering.
    static func probeCompletionResult(
        observedFingerprint: String?,
        error: (any Error)?
    ) -> Result<String, any Error> {
        if let observedFingerprint, !observedFingerprint.isEmpty {
            return .success(observedFingerprint)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .failure(CancellationError())
        }
        if let error {
            return .failure(ReadBoardGoConnectionError.networkFailure(from: error))
        }
        return .failure(ReadBoardGoConnectionError.certificateUnavailable)
    }
}

public final class PinnedHTTPSClient: RemoteRequestLoading, @unchecked Sendable {
    private let origin: PinnedHTTPSOrigin
    private let channelFactory: @Sendable () -> any PinnedHTTPSChannelLoading
    private let lock = NSLock()
    private var primary: any PinnedHTTPSChannelLoading

    fileprivate init(baseURL: URL, certificateFingerprint: String) {
        let origin = PinnedHTTPSOrigin(baseURL)
        let factory: @Sendable () -> any PinnedHTTPSChannelLoading = {
            PinnedHTTPSChannel(
                certificateFingerprint: certificateFingerprint,
                allowedOrigin: origin)
        }
        self.origin = origin
        channelFactory = factory
        primary = factory()
    }

    init(baseURL: URL,
         channelFactory: @escaping @Sendable () -> any PinnedHTTPSChannelLoading) {
        origin = PinnedHTTPSOrigin(baseURL)
        self.channelFactory = channelFactory
        primary = channelFactory()
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard origin.matches(request.url) else {
            throw ReadBoardGoConnectionError.unsafeRedirect
        }
        return try await Self.retryCancelledOnce(
            allowsRetry: Self.isRetrySafe(request)) { [self] attempt in
            if attempt == 0 {
                let result = try await currentChannel().data(for: request)
                try Self.rejectUnsafeRedirect(in: result.1, request: request,
                                              allowedOrigin: origin)
                return result
            }
            let retry = channelFactory()
            let result = try await retry.data(for: request)
            try Self.rejectUnsafeRedirect(in: result.1, request: request,
                                          allowedOrigin: origin)
            replacePrimary(with: retry)
            return result
        }
    }

    private func currentChannel() -> any PinnedHTTPSChannelLoading {
        lock.lock()
        let value = primary
        lock.unlock()
        return value
    }

    private func replacePrimary(with channel: any PinnedHTTPSChannelLoading) {
        lock.lock()
        primary = channel
        lock.unlock()
    }

    static func shouldRetry(error: any Error, taskIsCancelled: Bool) -> Bool {
        guard !taskIsCancelled, !(error is CancellationError),
              let urlError = error as? URLError else { return false }
        return urlError.code == .cancelled
    }

    static func normalized(error: any Error, taskIsCancelled: Bool) -> any Error {
        if taskIsCancelled || error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return ReadBoardGoConnectionError.requestCancelled
        }
        return error
    }

    static func retryCancelledOnce<Value: Sendable>(
        allowsRetry: Bool,
        operation: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation(0)
        } catch {
            guard allowsRetry,
                  shouldRetry(error: error, taskIsCancelled: Task.isCancelled) else {
                throw normalized(error: error, taskIsCancelled: Task.isCancelled)
            }
        }
        do {
            return try await operation(1)
        } catch {
            throw normalized(error: error, taskIsCancelled: Task.isCancelled)
        }
    }

    static func isRetrySafe(_ request: URLRequest) -> Bool {
        switch (request.httpMethod ?? "GET").uppercased() {
        case "GET", "HEAD", "OPTIONS": true
        default: false
        }
    }

    private static func rejectUnsafeRedirect(
        in response: URLResponse,
        request: URLRequest,
        allowedOrigin: PinnedHTTPSOrigin
    ) throws {
        guard let http = response as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else { return }
        guard let target = URL(string: location, relativeTo: request.url),
              allowedOrigin.matches(target) else {
            throw ReadBoardGoConnectionError.unsafeRedirect
        }
    }
}

protocol PinnedHTTPSChannelLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class PinnedHTTPSChannel: PinnedHTTPSChannelLoading, @unchecked Sendable {
    private let certificateFingerprint: String
    private let allowedOrigin: PinnedHTTPSOrigin?

    init(certificateFingerprint: String, allowedOrigin: PinnedHTTPSOrigin?) {
        self.certificateFingerprint = certificateFingerprint
        self.allowedOrigin = allowedOrigin
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard allowedOrigin?.matches(request.url) ?? true else {
            throw ReadBoardGoConnectionError.unsafeRedirect
        }
        return try await PinnedHTTP1Request(
            request: request,
            expectedFingerprint: certificateFingerprint
        ).perform()
    }
}

private struct PinnedHTTPSOrigin: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int

    init(_ url: URL) {
        scheme = url.scheme?.lowercased() ?? ""
        host = url.host?.lowercased() ?? ""
        port = url.port ?? (scheme == "https" ? 443 : -1)
    }

    func matches(_ url: URL?) -> Bool {
        guard let url else { return false }
        return self == PinnedHTTPSOrigin(url)
    }
}

/// ReadBoard API transport deliberately lives below URLSession/ATS. ATS performs
/// public-PKI policy before an app trust challenge on some older macOS releases,
/// which makes a correctly pinned self-signed server unusable. Network.framework
/// lets the exact same SecTrust pin be the TLS handshake verifier without relaxing
/// ATS for article images, WebKit, media, or any other app traffic.
final class PinnedHTTP1Request: @unchecked Sendable {
    private static let maximumResponseBytes = 128 * 1024 * 1024
    private let request: URLRequest
    private let expectedFingerprint: String
    private let queue = DispatchQueue(label: "com.liuhangbj.readboardgo.pinned-http")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var connection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var responseData = Data()
    private var finished = false

    init(request: URLRequest, expectedFingerprint: String) {
        self.request = request
        self.expectedFingerprint = PinnedHTTPS.normalized(expectedFingerprint)
    }

    func perform() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func begin(
        continuation: CheckedContinuation<(Data, URLResponse), any Error>
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 443),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            continuation.resume(throwing: ReadBoardGoConnectionError.tlsRequired)
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let tls = NWProtocolTLS.Options()
        let verifyQueue = queue
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { [weak self, expectedFingerprint] _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                switch PinnedHTTPS.pinnedTrust(
                    for: trust,
                    expectedFingerprint: expectedFingerprint
                ) {
                case .success: complete(true)
                case .failure(let error):
                    self?.finish(.failure(error))
                    complete(false)
                }
            },
            verifyQueue)
        sec_protocol_options_add_tls_application_protocol(
            tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        lock.lock()
        guard !finished else {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        let seconds = max(1, request.timeoutInterval > 0 ? request.timeoutInterval : 20)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
        timeoutWorkItem = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
        connection.start(queue: queue)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            do {
                let data = try Self.serializedRequest(request)
                connection?.send(content: data, completion: .contentProcessed {
                    [weak self] error in
                    if let error { self?.finish(.failure(Self.transportError(error))) }
                })
                receiveNext()
            } catch {
                finish(.failure(error))
            }
        case .failed(let error):
            finish(.failure(Self.transportError(error)))
        case .cancelled:
            finish(.failure(CancellationError()))
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { responseData.append(data) }
            if responseData.count > Self.maximumResponseBytes {
                finish(.failure(ReadBoardGoConnectionError.connectionFailed))
            } else if let error {
                finish(.failure(Self.transportError(error)))
            } else if isComplete {
                do {
                    finish(.success(try Self.parseResponse(responseData, request: request)))
                } catch {
                    finish(.failure(error))
                }
            } else {
                receiveNext()
            }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        timeout?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(with: result)
    }

    static func serializedRequest(_ request: URLRequest) throws -> Data {
        guard let url = request.url, let host = url.host else {
            throw ReadBoardGoConnectionError.invalidServerAddress
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard isValidHTTPToken(method) else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        guard let components = URLComponents(
            url: url, resolvingAgainstBaseURL: false) else {
            throw ReadBoardGoConnectionError.invalidServerAddress
        }
        let target = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        let requestTarget = target + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard !containsForbiddenHeaderValue(requestTarget) else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        let port = url.port ?? 443
        let escapedHost = host.contains(":") ? "[\(host)]" : host
        let hostValue = port == 443 ? escapedHost : "\(escapedHost):\(port)"
        var headers = request.allHTTPHeaderFields ?? [:]
        for protected in [
            "Host", "Connection", "Accept-Encoding", "Content-Length",
            "Transfer-Encoding", "TE", "Trailer", "Upgrade",
        ] {
            headers.keys.filter { $0.caseInsensitiveCompare(protected) == .orderedSame }
                .forEach { headers.removeValue(forKey: $0) }
        }
        headers["Host"] = hostValue
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        let body = request.httpBody ?? Data()
        if !body.isEmpty { headers["Content-Length"] = String(body.count) }
        for (name, value) in headers {
            guard isValidHTTPToken(name), !containsForbiddenHeaderValue(value) else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
        }
        var head = "\(method) \(requestTarget) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func parseResponse(
        _ data: Data, request: URLRequest
    ) throws -> (Data, URLResponse) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let status = Int(statusParts[1]), (100...599).contains(status) else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard isValidHTTPToken(name), !containsForbiddenHeaderValue(value) else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            if let existingKey = headers.keys.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }), let existing = headers[existingKey] {
                headers[existingKey] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        var rawBody = Data(data[range.upperBound...])
        let transferEncoding = headers.first { $0.key.caseInsensitiveCompare(
            "Transfer-Encoding") == .orderedSame }?.value.lowercased()
        let contentLength = headers.first { $0.key.caseInsensitiveCompare(
            "Content-Length") == .orderedSame }.flatMap { Int($0.value) }
        let body: Data
        if transferEncoding?.contains("chunked") == true {
            body = try decodeChunked(rawBody)
        } else if let contentLength {
            guard contentLength >= 0, rawBody.count >= contentLength else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            rawBody = Data(rawBody.prefix(contentLength))
            body = rawBody
        } else {
            body = rawBody
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers) else {
            throw ReadBoardGoConnectionError.connectionFailed
        }
        return (body, response)
    }

    static func decodeChunked(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[cursor...].range(of: crlf)?.lowerBound,
                  let line = String(data: data[cursor..<lineEnd], encoding: .utf8),
                  let size = Int(line.split(separator: ";", maxSplits: 1)[0], radix: 16),
                  size >= 0 else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            cursor = data.index(lineEnd, offsetBy: 2)
            if size == 0 { return decoded }
            guard let bodyEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex),
                  bodyEnd <= data.endIndex else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            decoded.append(data[cursor..<bodyEnd])
            guard data.distance(from: bodyEnd, to: data.endIndex) >= 2 else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            guard data[bodyEnd..<data.index(bodyEnd, offsetBy: 2)] == crlf else {
                throw ReadBoardGoConnectionError.connectionFailed
            }
            cursor = data.index(bodyEnd, offsetBy: 2)
        }
    }

    fileprivate static func transportError(_ error: NWError) -> any Error {
        switch error {
        case .posix(let code):
            switch code {
            case .ETIMEDOUT: return URLError(.timedOut)
            case .ECONNREFUSED: return URLError(.cannotConnectToHost)
            case .ENETDOWN, .ENETUNREACH, .ENOTCONN: return URLError(.notConnectedToInternet)
            default: return URLError(.networkConnectionLost)
            }
        case .dns: return URLError(.cannotFindHost)
        case .tls: return ReadBoardGoConnectionError.secureConnectionFailed
        default: return ReadBoardGoConnectionError.connectionFailed
        }
    }

    private static func isValidHTTPToken(_ value: String) -> Bool {
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7f && !separators.contains($0)
        }
    }

    private static func containsForbiddenHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0x7f || (scalar.value < 0x20 && scalar.value != 0x09)
        }
    }
}

private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate,
                                                URLSessionTaskDelegate,
                                                @unchecked Sendable {
    private let expectedFingerprint: String
    private let allowedOrigin: PinnedHTTPSOrigin?
    private let lock = NSLock()
    private var storedRejection: ReadBoardGoConnectionError?

    init(expectedFingerprint: String, allowedOrigin: PinnedHTTPSOrigin?) {
        self.expectedFingerprint = PinnedHTTPS.normalized(expectedFingerprint)
        self.allowedOrigin = allowedOrigin
    }

    var rejection: ReadBoardGoConnectionError? {
        lock.lock()
        let value = storedRejection
        lock.unlock()
        return value
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable
                        (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            recordRejection(.certificateUnavailable)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch PinnedHTTPS.credential(
            for: trust,
            expectedFingerprint: expectedFingerprint
        ) {
        case .success(let credential):
            completionHandler(.useCredential, credential)
        case .failure(let rejection):
            recordRejection(rejection)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard allowedOrigin?.matches(request.url) ?? true else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func recordRejection(_ rejection: ReadBoardGoConnectionError) {
        lock.lock()
        if storedRejection == nil { storedRejection = rejection }
        lock.unlock()
    }
}

private final class TLSCertificateProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.liuhangbj.readboardgo.certificate-probe")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var connection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var finished = false

    func inspect(baseURL: URL) async throws -> String {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host,
              let rawPort = UInt16(exactly: baseURL.port ?? 443),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw ReadBoardGoConnectionError.tlsRequired
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(host: host, port: port, continuation: continuation)
            }
        } onCancel: {
            self.complete(.failure(CancellationError()))
        }
    }

    private func begin(
        host: String,
        port: NWEndpoint.Port,
        continuation: CheckedContinuation<String, any Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { [weak self] _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let fingerprint = PinnedHTTPS.fingerprint(trust: trust) else {
                    complete(false)
                    self?.complete(.failure(
                        ReadBoardGoConnectionError.certificateUnavailable))
                    return
                }
                self?.complete(.success(fingerprint))
                complete(false)
            },
            queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: parameters)
        lock.lock()
        guard !finished else {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.complete(.failure(PinnedHTTP1Request.transportError(error)))
            case .cancelled:
                self?.complete(.failure(CancellationError()))
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.complete(.failure(URLError(.timedOut)))
        }
        timeoutWorkItem = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.start(queue: queue)
    }

    private func complete(_ result: Result<String, any Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        timeout?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation.resume(with: result)
    }
}

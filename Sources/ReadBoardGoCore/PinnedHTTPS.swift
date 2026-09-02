import CryptoKit
import Foundation
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
    /// only hostname validation while preserving date and signature validation.
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
    private let delegate: PinnedCertificateDelegate
    private let session: URLSession

    init(certificateFingerprint: String, allowedOrigin: PinnedHTTPSOrigin?) {
        delegate = PinnedCertificateDelegate(
            expectedFingerprint: certificateFingerprint,
            allowedOrigin: allowedOrigin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration,
                             delegate: delegate, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            if let rejection = delegate.rejection { throw rejection }
            return result
        } catch {
            if let rejection = delegate.rejection { throw rejection }
            throw error
        }
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

private final class TLSCertificateProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var session: URLSession?
    private var finished = false
    private var observedFingerprint: String?

    func inspect(baseURL: URL) async throws -> String {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw ReadBoardGoConnectionError.tlsRequired
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration,
                                     delegate: self, delegateQueue: nil)
            self.session = session
            let url = URL(string: "health", relativeTo: baseURL) ?? baseURL
            session.dataTask(with: url) { [weak self] _, _, error in
                guard let self else { return }
                self.complete(PinnedHTTPS.probeCompletionResult(
                    observedFingerprint: self.currentObservedFingerprint(),
                    error: error))
            }.resume()
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable
                        (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let fingerprint = PinnedHTTPS.fingerprint(trust: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            complete(.failure(ReadBoardGoConnectionError.certificateUnavailable))
            return
        }
        recordObservedFingerprint(fingerprint)
        completionHandler(.cancelAuthenticationChallenge, nil)
        complete(.success(fingerprint))
    }

    private func recordObservedFingerprint(_ fingerprint: String) {
        lock.lock()
        if !finished { observedFingerprint = fingerprint }
        lock.unlock()
    }

    private func currentObservedFingerprint() -> String? {
        lock.lock()
        let value = observedFingerprint
        lock.unlock()
        return value
    }

    private func complete(_ result: Result<String, any Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation.resume(with: result)
        session?.invalidateAndCancel()
    }
}

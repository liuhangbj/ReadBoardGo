import CryptoKit
import Foundation
import Security

public enum PinnedHTTPS {
    public static func session(certificateFingerprint: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let delegate = PinnedCertificateDelegate(expectedFingerprint: certificateFingerprint)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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

private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate,
                                                @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = PinnedHTTPS.normalized(expectedFingerprint)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable
                        (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let fingerprint = PinnedHTTPS.fingerprint(trust: trust),
              PinnedHTTPS.normalized(fingerprint) == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
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

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
                if let error { self?.complete(.failure(error)) }
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
        completionHandler(.cancelAuthenticationChallenge, nil)
        complete(.success(fingerprint))
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

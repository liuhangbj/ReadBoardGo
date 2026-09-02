import Foundation
import ReadBoardContract
import Security
import XCTest
@testable import ReadBoardGoCore

final class PinnedHTTPSTests: XCTestCase {
    func testExactPinAcceptsSelfSignedLeafWithoutHostnameSAN() throws {
        let certificateData = try XCTUnwrap(Data(
            base64Encoded: Self.selfSignedCertificateDER,
            options: .ignoreUnknownCharacters))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(
            nil, certificateData as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, "reader.example.com" as CFString),
            &trust), errSecSuccess)
        let resolvedTrust = try XCTUnwrap(trust)
        let fingerprint = try XCTUnwrap(PinnedHTTPS.fingerprint(trust: resolvedTrust))

        let acceptedTrust = PinnedHTTPS.pinnedTrust(
            for: resolvedTrust,
            expectedFingerprint: fingerprint
        )
        switch acceptedTrust {
        case .success(let pinnedTrust):
            XCTAssertFalse(pinnedTrust === resolvedTrust,
                           "固定证书凭据不得复用带主机名策略的原始 trust")
            var trustError: CFError?
            XCTAssertTrue(SecTrustEvaluateWithError(pinnedTrust, &trustError))

            XCTAssertEqual(SecTrustSetVerifyDate(
                pinnedTrust,
                Date(timeIntervalSince1970: 2_208_988_800) as CFDate), errSecSuccess)
            trustError = nil
            XCTAssertFalse(SecTrustEvaluateWithError(pinnedTrust, &trustError),
                           "Basic X.509 trust 仍必须拒绝超过有效期的固定证书")
        case .failure(let error):
            XCTFail("精确固定的自签名证书应建立凭据：\(error)")
        }

        switch PinnedHTTPS.credential(
            for: resolvedTrust,
            expectedFingerprint: String(repeating: "0", count: 64)
        ) {
        case .success:
            XCTFail("错误证书指纹不得建立凭据")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription,
                           ReadBoardGoConnectionError.certificateNotTrusted.localizedDescription)
        }
    }

    func testProbeCancellationAfterObservingCertificateReturnsFingerprint() throws {
        let fingerprint = String(repeating: "a", count: 64)
        let result = PinnedHTTPS.probeCompletionResult(
            observedFingerprint: fingerprint,
            error: URLError(.secureConnectionFailed))
        XCTAssertEqual(try result.get(), fingerprint)
    }

    func testProbeWithoutCertificateFailsClosedWhenTaskHasNoError() {
        let result = PinnedHTTPS.probeCompletionResult(
            observedFingerprint: nil,
            error: nil)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error.localizedDescription, "无法读取服务器 TLS 证书")
        }
    }

    func testProbeNetworkErrorsUseChineseActionableMessages() {
        let cases: [(URLError.Code, String)] = [
            (.cannotFindHost, "找不到服务器，请检查动态域名或服务器地址"),
            (.cannotConnectToHost, "无法连接服务器，请确认远程访问已开启且端口可达"),
            (.timedOut, "连接服务器超时，请检查网络和端口转发"),
            (.secureConnectionFailed, "无法建立 TLS 安全连接，请检查代理、服务器地址或证书"),
        ]

        for (code, expected) in cases {
            let result = PinnedHTTPS.probeCompletionResult(
                observedFingerprint: nil,
                error: URLError(code))
            XCTAssertThrowsError(try result.get()) { error in
                XCTAssertEqual(error.localizedDescription, expected)
            }
        }
    }

    func testPinnedCancellationIsNotReportedAsCertificateChange() {
        XCTAssertEqual(
            ReadBoardGoConnectionError.userFacingDescription(
                for: URLError(.cancelled), certificateWasPinned: true),
            "连接请求被系统取消，请检查代理或 VPN 后重试")
        XCTAssertEqual(
            ReadBoardGoConnectionError.userFacingDescription(
                for: URLError(.timedOut), certificateWasPinned: true),
            "连接服务器超时，请检查网络和端口转发")
        XCTAssertEqual(
            ReadBoardGoConnectionError.certificateNotTrusted.localizedDescription,
            "服务器证书未受信任或已发生变化")
    }

    func testPinnedClientRetriesOnlyUnownedCancellationOnce() {
        XCTAssertTrue(PinnedHTTPSClient.shouldRetry(
            error: URLError(.cancelled), taskIsCancelled: false))
        XCTAssertFalse(PinnedHTTPSClient.shouldRetry(
            error: URLError(.cancelled), taskIsCancelled: true))
        XCTAssertFalse(PinnedHTTPSClient.shouldRetry(
            error: URLError(.timedOut), taskIsCancelled: false))
        XCTAssertTrue(PinnedHTTPSClient.normalized(
            error: URLError(.cancelled), taskIsCancelled: true) is CancellationError)
        XCTAssertEqual(
            PinnedHTTPSClient.normalized(
                error: URLError(.cancelled), taskIsCancelled: false).localizedDescription,
            "连接请求被系统取消，请检查代理或 VPN 后重试")
    }

    func testPinnedClientRebuildsOnceAfterTransientCancellation() async throws {
        let attempt = try await PinnedHTTPSClient.retryCancelledOnce(
            allowsRetry: true) { attempt in
            if attempt == 0 { throw URLError(.cancelled) }
            return attempt
        }
        XCTAssertEqual(attempt, 1)

        do {
            _ = try await PinnedHTTPSClient.retryCancelledOnce(
                allowsRetry: true) { _ -> Int in
                throw URLError(.cancelled)
            }
            XCTFail("连续取消不得无限重试")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "连接请求被系统取消，请检查代理或 VPN 后重试")
        }
    }

    func testPinnedClientNeverRetriesLoginOrOtherWriteRequests() async {
        var post = URLRequest(url: URL(string: "https://reader.example.com/api/v1/login")!)
        post.httpMethod = "POST"
        XCTAssertFalse(PinnedHTTPSClient.isRetrySafe(post))
        XCTAssertTrue(PinnedHTTPSClient.isRetrySafe(
            URLRequest(url: URL(string: "https://reader.example.com/api/v1/server/profile")!)))

        do {
            _ = try await PinnedHTTPSClient.retryCancelledOnce(
                allowsRetry: false) { attempt -> Int in
                if attempt > 0 { XCTFail("写请求不得进入第二次尝试") }
                throw URLError(.cancelled)
            }
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "连接请求被系统取消，请检查代理或 VPN 后重试")
        }
    }

    func testPinnedClientDataCallsPostOnceAndSafeReadTwiceOnCancellation() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://reader.example.com:7331"))

        let postCounter = PinnedAttemptCounter()
        let postClient = PinnedHTTPSClient(baseURL: baseURL) {
            AlwaysCancelledPinnedChannel(counter: postCounter)
        }
        var post = URLRequest(url: try XCTUnwrap(
            URL(string: "api/v1/login", relativeTo: baseURL)))
        post.httpMethod = "POST"
        do {
            _ = try await postClient.data(for: post)
            XCTFail("取消的登录请求应失败")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "连接请求被系统取消，请检查代理或 VPN 后重试")
        }
        let postAttempts = await postCounter.value()
        XCTAssertEqual(postAttempts, 1)

        let getCounter = PinnedAttemptCounter()
        let getClient = PinnedHTTPSClient(baseURL: baseURL) {
            AlwaysCancelledPinnedChannel(counter: getCounter)
        }
        let profile = URLRequest(url: try XCTUnwrap(
            URL(string: "api/v1/server/profile", relativeTo: baseURL)))
        do {
            _ = try await getClient.data(for: profile)
            XCTFail("连续两次取消的 profile 应失败")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "连接请求被系统取消，请检查代理或 VPN 后重试")
        }
        let getAttempts = await getCounter.value()
        XCTAssertEqual(getAttempts, 2)
    }

    func testPinnedClientRejectsCrossOriginBeforeSendingRequest() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://reader.example.com:7331"))
        let client = PinnedHTTPS.client(
            baseURL: baseURL,
            certificateFingerprint: String(repeating: "a", count: 64))
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://evil.example.com/")))
        do {
            _ = try await client.data(for: request)
            XCTFail("跨域请求不应进入固定证书会话")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "服务器返回了不安全的跨域跳转，连接已停止")
        }
    }

    func testPinnedHTTP1SerializesEscapedTargetAndProtectsTransportHeaders() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://reader.example.com:7331/api/v1/search?q=%E4%B8%AD%E6%96%87")))
        request.httpMethod = "POST"
        request.setValue("attacker.example", forHTTPHeaderField: "host")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("999", forHTTPHeaderField: "content-length")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let serialized = try PinnedHTTP1Request.serializedRequest(request)
        let text = try XCTUnwrap(String(data: serialized, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(
            "POST /api/v1/search?q=%E4%B8%AD%E6%96%87 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: reader.example.com:7331\r\n"))
        XCTAssertTrue(text.contains("Accept-Encoding: identity\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertFalse(text.contains("attacker.example"))
    }

    func testPinnedHTTP1ParsesContentLengthAndChunkedResponses() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://reader.example.com:7331/health")))
        let contentLengthResponse = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Test: yes\r\n\r\nokextra".utf8)
        let (body, response) = try PinnedHTTP1Request.parseResponse(
            contentLengthResponse, request: request)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(
            forHTTPHeaderField: "X-Test"), "yes")

        let chunkedResponse = Data((
            "HTTP/1.1 400 Bad Request\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5\r\nhello\r\n6;ext=x\r\n world\r\n0\r\n\r\n").utf8)
        let (chunkedBody, chunkedHTTP) = try PinnedHTTP1Request.parseResponse(
            chunkedResponse, request: request)
        XCTAssertEqual(String(decoding: chunkedBody, as: UTF8.self), "hello world")
        XCTAssertEqual((chunkedHTTP as? HTTPURLResponse)?.statusCode, 400)
    }

    func testPinnedHTTP1RejectsHeaderInjectionAndMalformedChunking() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://reader.example.com:7331/health")))
        request.setValue("safe\r\nInjected: value", forHTTPHeaderField: "X-Test")
        XCTAssertThrowsError(try PinnedHTTP1Request.serializedRequest(request))
        XCTAssertThrowsError(try PinnedHTTP1Request.decodeChunked(
            Data("5\r\nhelloXX0\r\n\r\n".utf8)))
    }

    func testPinnedClientClassifiesCrossOriginRedirectPerRequest() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://reader.example.com:7331"))
        let recorder = PinnedRequestRecorder()
        let channel = RedirectingPinnedChannel(recorder: recorder)
        let client = PinnedHTTPSClient(baseURL: baseURL) { channel }

        let redirect = URLRequest(url: try XCTUnwrap(
            URL(string: "redirect", relativeTo: baseURL)))
        do {
            _ = try await client.data(for: redirect)
            XCTFail("跨域跳转应按当前请求拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "服务器返回了不安全的跨域跳转，连接已停止")
        }

        let ok = URLRequest(url: try XCTUnwrap(URL(string: "ok", relativeTo: baseURL)))
        let (_, response) = try await client.data(for: ok)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let paths = await recorder.paths()
        XCTAssertEqual(paths, ["/redirect", "/ok"])
    }

    @MainActor
    func testNewerServerInspectionWinsWhenOlderRequestFinishesLater() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-go-tls-race-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let session = ReadBoardGoSession(
            store: EmptyConnectionStore(),
            offlineCache: ReadBoardGoOfflineCache(fileURL: cacheURL),
            certificateInspector: { url in
                if url.host == "old.example.com" {
                    try await Task.sleep(for: .milliseconds(100))
                    return String(repeating: "a", count: 64)
                }
                return String(repeating: "b", count: 64)
            })

        let older = Task { @MainActor in
            await session.inspectServer(address: "https://old.example.com:7331")
        }
        try await Task.sleep(for: .milliseconds(10))
        await session.inspectServer(address: "https://new.example.com:7331")
        await older.value

        XCTAssertEqual(session.trustCandidate?.baseURL.host, "new.example.com")
        XCTAssertEqual(session.trustCandidate?.certificateFingerprint,
                       String(repeating: "b", count: 64))
        XCTAssertFalse(session.isWorking)
    }

    func testLiveCertificateProbeAndStrictPinningWhenEnabled() async throws {
        guard let raw = ProcessInfo.processInfo.environment["READBOARD_GO_LIVE_SERVER"],
              let baseURL = URL(string: raw) else {
            throw XCTSkip("实时 ReadBoard TLS 测试默认关闭")
        }

        var fingerprints = Set<String>()
        for _ in 0..<20 {
            fingerprints.insert(try await PinnedHTTPS.inspectCertificate(at: baseURL))
        }
        XCTAssertEqual(fingerprints.count, 1)
        let fingerprint = try XCTUnwrap(fingerprints.first)
        XCTAssertEqual(fingerprint.count, 64)

        let accepted = PinnedHTTPS.client(
            baseURL: baseURL, certificateFingerprint: fingerprint)
        let healthURL = try XCTUnwrap(URL(string: "health", relativeTo: baseURL))
        let (data, response) = try await accepted.data(for: URLRequest(url: healthURL))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("apiVersion"))

        let loginURL = try XCTUnwrap(URL(string: "api/v1/login", relativeTo: baseURL))
        var malformedLogin = URLRequest(url: loginURL)
        malformedLogin.httpMethod = "POST"
        malformedLogin.setValue(ReadBoardRemoteAPI.version,
                                forHTTPHeaderField: ReadBoardRemoteAPI.versionHeader)
        malformedLogin.setValue("application/json", forHTTPHeaderField: "Content-Type")
        malformedLogin.httpBody = Data("{}".utf8)
        let (_, loginResponse) = try await accepted.data(for: malformedLogin)
        XCTAssertEqual((loginResponse as? HTTPURLResponse)?.statusCode, 400)

        let profileURL = try XCTUnwrap(
            URL(string: "api/v1/server/profile", relativeTo: baseURL))
        var profileRequest = URLRequest(url: profileURL)
        profileRequest.setValue(ReadBoardRemoteAPI.version,
                                forHTTPHeaderField: ReadBoardRemoteAPI.versionHeader)
        let (_, profileResponse) = try await accepted.data(for: profileRequest)
        XCTAssertEqual((profileResponse as? HTTPURLResponse)?.statusCode, 401)

        let rejected = PinnedHTTPS.client(
            baseURL: baseURL,
            certificateFingerprint: String(repeating: "0", count: 64))
        do {
            _ = try await rejected.data(for: URLRequest(url: healthURL))
            XCTFail("错误证书指纹不应读取服务器响应")
        } catch {
            XCTAssertEqual(error.localizedDescription, "服务器证书未受信任或已发生变化")
        }
    }

    private static let selfSignedCertificateDER = """
    MIICwDCCAagCCQCHuvW/rABsPjANBgkqhkiG9w0BAQsFADAiMSAwHgYDVQQDDBdSZWFkQm9hcmQgTG9jYWwgU2VydmljZTAeFw0yNjA4MDgxNTIxNTlaFw0zNjA4MDUxNTIxNTlaMCIxIDAeBgNVBAMMF1JlYWRCb2FyZCBMb2NhbCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzLM0GSQ15uABGIFVKLT2yYkL9cBBAd9DtdApo2cHXLlMWgW+chaD1ewRZe9jCKllOh64aapYM5sAjdwRjye6OTMsLFCU1O9seerfimbfAoURfnoeEZCIt5TovJ8oA7gZKV7OGZhqU30p2J7Z23BbO+WYK0yfQNysT02az/RW2SqelPU1a9wVamM6SUHHc3KqKFM/IZbwfLMkbj9S7veNE9iRIMw678lilLa91cm6mYp4AlZ8fOvGOXXS+2rsuiu+znMqRqus1mupojRfQrW/x5xBb8uz6sViUVor74/ZgBnBSloCjD/Hs8kYr+Vgi8FOmmkelHc5ZrovSG8sEHObXQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQALyP9TXgOlBnjpFLPIFl5XFuvI6fE2Yvka8TG7rhzSAv6WG1tTL0O8NbjdAYCmypkS3E7OLvgq0ATinAudUugzSldRBsPa9PEhpt+bTUv1Ah6qLbx6ItSmODhsvbFyO4Oach3h5KeEKbr+3zkVTbSFGXbXU0UfhjqYLoU8JIv0OxKNPTuC81Ha/bA8qkh1PrZ2xzBP35WY2SNczSJ/sdlPGID1UD62iTLNtYVVkdsUMsPIz/PiPD9PSRcAWEztsswU9NgpxW/uddXIvjJK62qvg4vuMBR+dt+h7W9qmPC56o7S5LUiGbX+SV+AupyEBhQcVZLd/JfGjcFteS2lP6kR
    """
}

private struct EmptyConnectionStore: ConnectionStoring {
    func load() throws -> StoredServerConnection? { nil }
    func save(_ connection: StoredServerConnection) throws {}
    func delete() throws {}
}

private actor PinnedAttemptCounter {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private struct AlwaysCancelledPinnedChannel: PinnedHTTPSChannelLoading {
    let counter: PinnedAttemptCounter

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await counter.record()
        throw URLError(.cancelled)
    }
}

private actor PinnedRequestRecorder {
    private var recordedPaths: [String] = []
    func record(_ path: String) { recordedPaths.append(path) }
    func paths() -> [String] { recordedPaths }
}

private struct RedirectingPinnedChannel: PinnedHTTPSChannelLoading {
    let recorder: PinnedRequestRecorder

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        await recorder.record(url.path)
        if url.path == "/redirect" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://evil.example.com/target"])!
            return (Data(), response)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(), response)
    }
}

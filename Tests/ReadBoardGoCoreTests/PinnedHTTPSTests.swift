import Foundation
import XCTest
@testable import ReadBoardGoCore

final class PinnedHTTPSTests: XCTestCase {
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

    func testPinnedTLSFailureIsReportedAsCertificateChange() {
        let tlsCodes: [URLError.Code] = [
            .cancelled,
            .secureConnectionFailed,
            .serverCertificateUntrusted,
        ]
        for code in tlsCodes {
            XCTAssertEqual(
                ReadBoardGoConnectionError.userFacingDescription(
                    for: URLError(code), certificateWasPinned: true),
                "服务器证书未受信任或已发生变化")
        }
        XCTAssertEqual(
            ReadBoardGoConnectionError.userFacingDescription(
                for: URLError(.timedOut), certificateWasPinned: true),
            "连接服务器超时，请检查网络和端口转发")
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

        let accepted = PinnedHTTPS.session(certificateFingerprint: fingerprint)
        let healthURL = try XCTUnwrap(URL(string: "health", relativeTo: baseURL))
        let (data, response) = try await accepted.data(from: healthURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("apiVersion"))

        let rejected = PinnedHTTPS.session(
            certificateFingerprint: String(repeating: "0", count: 64))
        do {
            _ = try await rejected.data(from: healthURL)
            XCTFail("错误证书指纹不应读取服务器响应")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
    }
}

private struct EmptyConnectionStore: ConnectionStoring {
    func load() throws -> StoredServerConnection? { nil }
    func save(_ connection: StoredServerConnection) throws {}
    func delete() throws {}
}

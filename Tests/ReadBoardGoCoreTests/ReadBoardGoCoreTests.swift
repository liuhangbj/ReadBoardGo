import XCTest
@testable import ReadBoardGoCore
import ReadBoardContract

final class ReadBoardGoCoreTests: XCTestCase {
    func testServerAddressNormalizationAddsHTTPSAndDropsPaths() throws {
        XCTAssertEqual(try ServerAddressNormalizer.normalize("10.0.0.5:7331/path?x=1").absoluteString,
                       "https://10.0.0.5:7331/")
        XCTAssertEqual(try ServerAddressNormalizer.normalize("https://reader.example.com").absoluteString,
                       "https://reader.example.com/")
    }

    func testStoredConnectionRetainsGrantedScopes() throws {
        let credential = RemotePairingCredential(deviceID: "device", deviceName: "iPhone",
            token: "secret", apiVersion: "1", scopes: RemoteAccessScope.reader)
        let value = StoredServerConnection(baseURL: URL(string: "https://10.0.0.5:7331/")!,
                                           credential: credential,
                                           certificateFingerprint: String(repeating: "a", count: 64))
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(StoredServerConnection.self, from: data), value)
    }

    func testLiveTLSCertificatePinningWhenEnabled() async throws {
        guard let raw = ProcessInfo.processInfo.environment["READBOARD_GO_LIVE_SERVER"],
              let baseURL = URL(string: raw) else {
            throw XCTSkip("实时 ReadBoard TLS 测试默认关闭")
        }
        let fingerprint = try await PinnedHTTPS.inspectCertificate(at: baseURL)
        XCTAssertEqual(fingerprint.count, 64)
        let session = PinnedHTTPS.session(certificateFingerprint: fingerprint)
        let (data, response) = try await session.data(
            from: URL(string: "health", relativeTo: baseURL)!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("apiVersion"))
    }

    @MainActor
    func testLiveBonjourDiscoveryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_GO_LIVE_DISCOVERY"] == "1" else {
            throw XCTSkip("实时 Bonjour 测试默认关闭")
        }
        let discovery = ReadBoardDiscovery()
        discovery.start()
        defer { discovery.stop() }
        for _ in 0..<30 {
            if !discovery.servers.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(discovery.servers.isEmpty)
        XCTAssertTrue(discovery.servers.allSatisfy {
            $0.baseURLs.allSatisfy { $0.scheme == "https" }
        })
    }
}

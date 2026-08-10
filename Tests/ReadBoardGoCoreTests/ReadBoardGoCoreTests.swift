import Foundation
import XCTest
@testable import ReadBoardGoCore
import ReadBoardContract
import ReadBoardRemote

final class ReadBoardGoCoreTests: XCTestCase {
    func testMarkdownParserMatchesCoreReadingBlocks() {
        let markdown = """
        ---
        title: Example
        url: https://example.com
        ---

        # Heading

        Paragraph with **bold** and [link](https://example.com).

        - First
        2. Second

        > Quote

        ```swift
        let value = 1
        ```

        ![Cover](https://example.com/cover.jpg)
        """
        let blocks = GoMarkdownParser.parse(markdown)
        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(blocks[0], .frontmatter(text: "title: Example\nurl: https://example.com"))
        XCTAssertEqual(blocks[1], .heading(level: 1, text: "Heading"))
        XCTAssertEqual(blocks[2], .paragraph(text: "Paragraph with **bold** and [link](https://example.com)."))
        XCTAssertEqual(blocks[3], .listItem(ordered: false, index: 0, text: "First"))
        XCTAssertEqual(blocks[4], .listItem(ordered: true, index: 2, text: "Second"))
        XCTAssertEqual(blocks[5], .quote(text: "Quote"))
        XCTAssertEqual(blocks[6], .codeBlock(lang: "swift", code: "let value = 1"))
        XCTAssertEqual(blocks[7], .image(alt: "Cover", url: "https://example.com/cover.jpg"))
    }

    func testMarkdownParserSplitsMultipleImagesAndDropsTitles() {
        let blocks = GoMarkdownParser.parse(
            "![One](https://img.example/one.jpg) ![Two](https://img.example/two.jpg \"caption\")")
        XCTAssertEqual(blocks, [
            .image(alt: "One", url: "https://img.example/one.jpg"),
            .image(alt: "Two", url: "https://img.example/two.jpg"),
        ])
    }

    func testMarkdownParserAcceptsStandaloneHTMLImages() {
        let blocks = GoMarkdownParser.parse(
            #"<img src="https://img.example/one.jpg?a=1&amp;b=2" alt="One"><img src='https://img.example/two.jpg'>"#)
        XCTAssertEqual(blocks, [
            .image(alt: "One", url: "https://img.example/one.jpg?a=1&b=2"),
            .image(alt: "", url: "https://img.example/two.jpg"),
        ])
    }

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

    func testPermissionRequiresBothAdvertisedCapabilityAndGrantedScope() {
        let readOnly = ReadBoardPermissionSet(
            capabilities: [.library, .processing],
            scopes: [.readLibrary])
        XCTAssertTrue(readOnly.allows(.readLibrary, capability: .library))
        XCTAssertFalse(readOnly.allows(.updateReadingState, capability: .library))
        XCTAssertFalse(readOnly.allows(.readLibrary, capability: .export))
    }

    @MainActor
    func testRemoteHealthKeepsFailuresVisibleUntilTheirPathRecovers() {
        let store = ReadBoardRemoteHealthStore()
        store.receive(.failed(
            path: "api/v1/admin/dashboard",
            kind: .authorization,
            message: "HTTP 403"))
        store.receive(.failed(
            path: "api/v1/library/page",
            kind: .transport,
            message: "offline"))
        XCTAssertEqual(store.phase, .degraded)
        XCTAssertEqual(store.failingPaths.count, 2)

        store.receive(.succeeded(path: "api/v1/library/page"))
        XCTAssertEqual(store.failingPaths, Set(["api/v1/admin/dashboard"]))
        XCTAssertEqual(store.phase, .degraded)
        XCTAssertNotNil(store.message)

        store.receive(.succeeded(path: "api/v1/admin/dashboard"))
        XCTAssertEqual(store.phase, .healthy)
        XCTAssertNil(store.message)
    }

    func testFileConnectionStorePersistsWithoutKeychainInteraction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "readboard-go-store-test-\(UUID().uuidString)",
            isDirectory: true)
        let file = directory.appendingPathComponent("connection.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let credential = RemotePairingCredential(
            deviceID: "device",
            deviceName: "Mac",
            token: "secret",
            apiVersion: "1",
            scopes: RemoteAccessScope.fullControl)
        let value = StoredServerConnection(
            baseURL: URL(string: "https://10.0.0.5:7331/")!,
            credential: credential,
            certificateFingerprint: String(repeating: "b", count: 64))
        let store = FileConnectionStore(fileURL: file)

        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testOfflineCachePersistsLastKnownProfileSnapshotAndDetail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "readboard-go-offline-cache-test-\(UUID().uuidString)",
            isDirectory: true)
        let file = directory.appendingPathComponent("offline-cache.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let profile = RemoteServerProfile(
            apiVersion: "1",
            serverName: "ReadBoard Pro",
            capabilities: [.library, .mediaPlayback],
            grantedScopes: RemoteAccessScope.reader,
            transportSecurity: "tls")
        let counts = LibraryCountsSnapshot(
            total: 2, unread: 1,
            pending: 0, pendingUnread: 0,
            exported: 0, exportedUnread: 0,
            articles: 2, articleUnread: 1,
            podcasts: 0, podcastUnread: 0,
            videos: 0, videoUnread: 0)
        let snapshot = LibrarySnapshot(nodes: [], counts: counts)
        let detail = ContentDetail(
            id: 42,
            contentMarkdown: "正文",
            translatedMarkdown: "译文",
            transcriptMarkdown: nil,
            translatedTitle: "标题",
            audioURL: nil,
            videoID: nil,
            score: 8,
            summary: "摘要")

        let cache = ReadBoardGoOfflineCache(fileURL: file)
        await cache.storeProfile(profile)
        await cache.storeLibrarySnapshot(snapshot)
        await cache.storeDetail(detail)

        let restored = ReadBoardGoOfflineCache(fileURL: file)
        let restoredProfile = await restored.profile()
        let restoredSnapshot = await restored.librarySnapshot()
        let restoredDetail = await restored.detail(contentID: 42)
        let restoredStatus = await restored.status()
        XCTAssertEqual(restoredProfile, profile)
        XCTAssertEqual(restoredSnapshot, snapshot)
        XCTAssertEqual(restoredDetail, detail)
        XCTAssertNotNil(restoredStatus.updatedAt)
    }

    func testOfflineCacheDoesNotCrossServerBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("offline-cache.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ReadBoardGoOfflineCache(fileURL: fileURL)
        await cache.activate(serverKey: "https://server-a|fingerprint-a")
        let emptyCounts = LibraryCountsSnapshot(
            total: 0, unread: 0, pending: 0, pendingUnread: 0,
            exported: 0, exportedUnread: 0, articles: 0, articleUnread: 0,
            podcasts: 0, podcastUnread: 0, videos: 0, videoUnread: 0)
        await cache.storeLibrarySnapshot(LibrarySnapshot(nodes: [], counts: emptyCounts))
        let firstLibrary = await cache.librarySnapshot()
        XCTAssertNotNil(firstLibrary)

        await cache.activate(serverKey: "https://server-b|fingerprint-b")
        let switchedLibrary = await cache.librarySnapshot()
        let switchedProfile = await cache.profile()
        let switchedStatus = await cache.status()
        XCTAssertNil(switchedLibrary)
        XCTAssertNil(switchedProfile)
        XCTAssertEqual(switchedStatus.pendingReadingMutations, 0)
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

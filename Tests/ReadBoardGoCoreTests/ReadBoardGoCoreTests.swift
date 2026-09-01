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

    @MainActor
    func testStoredV1ConnectionIsRetainedForAutomaticServerUpgradeProbe() throws {
        let credential = RemotePairingCredential(
            deviceID: "device", deviceName: "Mac", token: "secret",
            apiVersion: "1", scopes: RemoteAccessScope.reader)
        let stored = StoredServerConnection(
            baseURL: try XCTUnwrap(URL(string: "https://10.0.0.5:7331/")),
            credential: credential,
            certificateFingerprint: String(repeating: "a", count: 64))
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-go-upgrade-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let session = ReadBoardGoSession(
            store: StaticConnectionStore(connection: stored),
            offlineCache: ReadBoardGoOfflineCache(fileURL: cacheURL))

        XCTAssertEqual(session.connection, stored)
        XCTAssertTrue(session.isRestoringConnection)
        XCTAssertNil(session.errorMessage)
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

    func testOfflineReadMutationKeepsSocialPagesAndNavigationCountsInSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("offline-cache.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let article = socialSummary(
            id: 101, contentType: "article", source: "xiaohongshu", sourceID: 11)
        let video = socialSummary(
            id: 102, contentType: "video", source: "douyin", sourceID: 12)
        let nodes = [
            LibraryNode(
                id: "folder:1", kind: .folder, name: "社交媒体", count: 2, unread: 2,
                sourceID: nil, folderID: 1,
                children: [
                    LibraryNode(
                        id: "source:11", kind: .source, name: "小红书", count: 1, unread: 1,
                        sourceID: 11, folderID: 1),
                    LibraryNode(
                        id: "source:12", kind: .source, name: "抖音", count: 1, unread: 1,
                        sourceID: 12, folderID: 1),
                ])
        ]
        let counts = LibraryCountsSnapshot(
            total: 2, unread: 2, pending: 0, pendingUnread: 0,
            exported: 0, exportedUnread: 0,
            articles: 0, articleUnread: 0,
            podcasts: 0, podcastUnread: 0,
            videos: 0, videoUnread: 0,
            socialArticles: 1, socialArticleUnread: 1,
            socialVideos: 1, socialVideoUnread: 1)
        let articleQuery = ContentQuery(filter: ContentFilter(
            category: .article, sourceFamily: .social))
        let videoQuery = ContentQuery(filter: ContentFilter(
            category: .video, sourceFamily: .social))

        let cache = ReadBoardGoOfflineCache(fileURL: fileURL)
        await cache.storeLibrarySnapshot(LibrarySnapshot(nodes: nodes, counts: counts))
        await cache.storePage(ContentPage(items: [article], nextCursor: nil), query: articleQuery)
        await cache.storePage(ContentPage(items: [video], nextCursor: nil), query: videoQuery)

        await cache.apply(ContentState(
            contentID: article.id, isRead: true, isStarred: false, updatedAt: 1))
        let articleSnapshot = await cache.librarySnapshot()
        var snapshot = try XCTUnwrap(articleSnapshot)
        XCTAssertEqual(snapshot.counts.unread, 1)
        XCTAssertEqual(snapshot.counts.socialArticleUnread, 0)
        XCTAssertEqual(snapshot.counts.socialVideoUnread, 1)
        XCTAssertEqual(snapshot.nodes[0].unread, 1)
        XCTAssertEqual(snapshot.nodes[0].children.map(\.unread), [0, 1])
        let updatedArticlePage = await cache.page(query: articleQuery)
        XCTAssertTrue(try XCTUnwrap(updatedArticlePage).items[0].isRead)

        await cache.apply(ContentState(
            contentID: video.id, isRead: true, isStarred: false, updatedAt: 2))
        // 重放同一目标状态必须幂等，不能把未读计数减成负数。
        await cache.apply(ContentState(
            contentID: video.id, isRead: true, isStarred: true, updatedAt: 3))
        let finalSnapshot = await cache.librarySnapshot()
        snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.counts.unread, 0)
        XCTAssertEqual(snapshot.counts.socialArticleUnread, 0)
        XCTAssertEqual(snapshot.counts.socialVideoUnread, 0)
        XCTAssertEqual(snapshot.nodes[0].unread, 0)
        XCTAssertEqual(snapshot.nodes[0].children.map(\.unread), [0, 0])
    }

    func testOfflineReadMutationKeepsInboxSocialBreakdownInSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("offline-cache.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ordinaryArticle = socialSummary(
            id: 201, contentType: "article", source: "web", sourceID: nil)
        let socialArticle = socialSummary(
            id: 202, contentType: "article", source: "xiaohongshu", sourceID: nil)
        let ordinaryVideo = socialSummary(
            id: 203, contentType: "video", source: "youtube", sourceID: nil)
        let socialVideo = socialSummary(
            id: 204, contentType: "video", source: "douyin", sourceID: nil)
        let query = ContentQuery(filter: ContentFilter(inboxOnly: true))
        let counts = LibraryCountsSnapshot(
            total: 4, unread: 4, pending: 0, pendingUnread: 0,
            exported: 0, exportedUnread: 0,
            articles: 1, articleUnread: 1,
            podcasts: 0, podcastUnread: 0,
            videos: 1, videoUnread: 1,
            socialArticles: 1, socialArticleUnread: 1,
            socialVideos: 1, socialVideoUnread: 1,
            inbox: 4, inboxUnread: 4,
            inboxArticles: 2, inboxArticleUnread: 2,
            inboxPodcasts: 0, inboxPodcastUnread: 0,
            inboxVideos: 2, inboxVideoUnread: 2,
            inboxSocialArticles: 1, inboxSocialArticleUnread: 1,
            inboxSocialVideos: 1, inboxSocialVideoUnread: 1)

        let cache = ReadBoardGoOfflineCache(fileURL: fileURL)
        await cache.storeLibrarySnapshot(LibrarySnapshot(nodes: [], counts: counts))
        await cache.storePage(ContentPage(
            items: [ordinaryArticle, socialArticle, ordinaryVideo, socialVideo],
            nextCursor: nil), query: query)

        await cache.apply(ContentState(
            contentID: socialArticle.id, isRead: true, isStarred: false, updatedAt: 1))
        let socialArticleSnapshot = await cache.librarySnapshot()
        var snapshot = try XCTUnwrap(socialArticleSnapshot)
        XCTAssertEqual(snapshot.counts.unread, 3)
        XCTAssertEqual(snapshot.counts.inboxUnread, 3)
        XCTAssertEqual(snapshot.counts.inboxArticleUnread, 1)
        XCTAssertEqual(snapshot.counts.inboxSocialArticleUnread, 0)
        XCTAssertEqual(snapshot.counts.articleUnread, 1)
        XCTAssertEqual(snapshot.counts.socialArticleUnread, 0)

        await cache.apply(ContentState(
            contentID: ordinaryVideo.id, isRead: true, isStarred: false, updatedAt: 2))
        // 重放同一目标状态仍应幂等。
        await cache.apply(ContentState(
            contentID: ordinaryVideo.id, isRead: true, isStarred: true, updatedAt: 3))
        let ordinaryVideoSnapshot = await cache.librarySnapshot()
        snapshot = try XCTUnwrap(ordinaryVideoSnapshot)
        XCTAssertEqual(snapshot.counts.unread, 2)
        XCTAssertEqual(snapshot.counts.inboxUnread, 2)
        XCTAssertEqual(snapshot.counts.inboxVideoUnread, 1)
        XCTAssertEqual(snapshot.counts.inboxSocialVideoUnread, 1)
        XCTAssertEqual(snapshot.counts.videoUnread, 0)
        XCTAssertEqual(snapshot.counts.socialVideoUnread, 1)
    }

    private func socialSummary(
        id: Int64,
        contentType: String,
        source: String,
        sourceID: Int64?
    ) -> ContentSummary {
        ContentSummary(
            id: id, contentType: contentType, source: source, sourceType: source,
            sourceID: sourceID, sourceName: source, title: "Sample", author: nil,
            url: "https://example.com/\(id)", language: nil, publishedAt: nil,
            excerpt: nil, score: nil, summary: nil, fetchStatus: 2,
            isRead: false, isStarred: false, imageURL: nil,
            hasTranslation: false, hasTranscript: false,
            isMedia: contentType == "video", translatedHead: nil,
            translatedTitle: nil, hasFulltext: true, hasExport: false,
            hasUnmetProcessing: false, accessState: nil)
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

private struct StaticConnectionStore: ConnectionStoring {
    let connection: StoredServerConnection?

    func load() throws -> StoredServerConnection? { connection }
    func save(_ connection: StoredServerConnection) throws {}
    func delete() throws {}
}

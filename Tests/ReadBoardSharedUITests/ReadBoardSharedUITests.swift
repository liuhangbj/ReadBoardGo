import XCTest
import ReadBoardContract
@testable import ReadBoardSharedUI

@MainActor
final class ReadBoardSharedUITests: XCTestCase {
    func testMarkdownKernelKeepsEveryImageAsAnIndependentRenderUnit() {
        let markdown = """
        开头正文

        ![第一张](https://example.com/one.jpg)

        ![第二张](https://example.com/two.jpg)

        结尾正文
        """

        let blocks = MarkdownRenderer.parse(markdown)
        let imageURLs = blocks.compactMap { block -> String? in
            guard case .image(_, let url) = block else { return nil }
            return url
        }

        XCTAssertEqual(imageURLs, [
            "https://example.com/one.jpg",
            "https://example.com/two.jpg",
        ])
        XCTAssertEqual(
            MarkdownBodyView.selectionUnitBlockCountsForTesting(markdown: markdown),
            [1, 1, 1, 1])
    }

    func testMarkdownKernelSupportsStandaloneHTMLImages() {
        let markdown = """
        正文

        <img src="https://example.com/first.png" alt="第一张">
        <img src="https://example.com/second.png" alt="第二张">
        """

        let imageURLs = MarkdownRenderer.parse(markdown).compactMap { block -> String? in
            guard case .image(_, let url) = block else { return nil }
            return url
        }

        XCTAssertEqual(imageURLs, [
            "https://example.com/first.png",
            "https://example.com/second.png",
        ])
    }

    func testReadingThemeAndFontSettingsRemainCompatibleWithCoreKeys() {
        XCTAssertEqual(ReadingTheme(rawValue: "claude"), .claude)
        XCTAssertEqual(ReadingTheme.Mode(rawValue: "system"), .system)
        XCTAssertEqual(ReadingFont.presets, [.system, .heiti, .kaiti, .fangsong])
    }

    func testReadingMetadataDateKeepsCoreUTCDateBoundary() {
        // 2026-08-08 18:30 UTC is already 2026-08-09 in China, but Core displayed
        // the stored UTC date prefix and the shared view must remain identical.
        XCTAssertEqual(ReadingView.metadataDateString(epoch: 1_786_213_800), "2026-08-08")
    }

    func testMediaReadingTabsKeepTranslationAndTranscriptIndependent() {
        XCTAssertEqual(
            ReadingView.mediaTabOptions(hasTranslation: false, hasTranscript: false).map(\.1),
            ["原文"])
        XCTAssertEqual(
            ReadingView.mediaTabOptions(hasTranslation: true, hasTranscript: false).map(\.1),
            ["原文", "译文"])
        XCTAssertEqual(
            ReadingView.mediaTabOptions(hasTranslation: false, hasTranscript: true).map(\.1),
            ["原文", "转录"])
        XCTAssertEqual(
            ReadingView.mediaTabOptions(hasTranslation: true, hasTranscript: true).map(\.1),
            ["原文", "译文", "转录"])
    }

    func testManualProcessingStateIsSharedWithDashboardProjection() {
        let contentID = Int64.min + 20260809
        let store = ContentProcessingStateStore.shared
        store.clear(contentId: contentID)

        store.enqueue(contentId: contentID, title: "共享阅读任务", operation: "AI 翻译")
        XCTAssertEqual(store.state(for: contentID)?.phase, .queued)
        XCTAssertTrue(store.dashboardEntries.contains { $0.contentId == contentID })

        store.begin(contentId: contentID, message: "处理中")
        XCTAssertTrue(store.state(for: contentID)?.isProcessing == true)

        store.finish(contentId: contentID, message: "处理完成", succeeded: true)
        XCTAssertEqual(store.state(for: contentID)?.phase, .succeeded)
        XCTAssertTrue(store.dashboardEntries.contains { $0.contentId == contentID })

        store.clear(contentId: contentID)
        XCTAssertNil(store.state(for: contentID))
    }

    func testSharedLibraryModelLoadsSelectsAndWritesBackState() async throws {
        let item = makeSummary(id: 42, isRead: false, isStarred: false)
        let source = LibraryNode(
            id: "s7", kind: .source, name: "测试源", count: 1, unread: 1,
            sourceID: 7, folderID: 3)
        let folder = LibraryNode(
            id: "f3", kind: .folder, name: "测试文件夹", count: 1, unread: 1,
            sourceID: nil, folderID: 3, children: [source])
        let gateway = SharedLibraryGatewaySpy(
            page: ContentPage(items: [item], nextCursor: nil),
            snapshot: LibrarySnapshot(
                nodes: [folder],
                counts: LibraryCountsSnapshot(
                    total: 1, unread: 1,
                    pending: 0, pendingUnread: 0,
                    exported: 0, exportedUnread: 0,
                    articles: 1, articleUnread: 1,
                    podcasts: 0, podcastUnread: 0,
                    videos: 0, videoUnread: 0)))
        let model = ContentViewModel(library: gateway)

        model.loadAll()
        try await waitUntil { model.items.count == 1 && model.sidebarTree.count == 1 }
        XCTAssertEqual(model.items.first?.id, 42)
        XCTAssertEqual(model.totalUnread, 1)

        model.open(item)
        XCTAssertEqual(model.selectedItem?.id, 42)
        XCTAssertTrue(model.selectedItem?.isRead == true)
        try await waitUntil { model.totalUnread == 0 }
        XCTAssertEqual(model.sidebarTree.first?.unread, 0)
        let readCalls = await gateway.readCalls()
        XCTAssertEqual(readCalls, [.init(contentID: 42, isRead: true)])

        model.toggleStar(item)
        XCTAssertTrue(model.items.first?.isStarred == true)
        XCTAssertTrue(model.selectedItem?.isStarred == true)
        try await waitUntil { await gateway.starCalls().count == 1 }
        let starCalls = await gateway.starCalls()
        XCTAssertEqual(starCalls, [.init(contentID: 42, isStarred: true)])

        // 右栏工具条通过同一通知回填权威状态；中栏选中项和行状态必须同步。
        NotificationCenter.default.post(
            name: .readBoardContentUpdated,
            object: ContentState(
                contentID: 42,
                isRead: false,
                isStarred: false,
                updatedAt: 2))
        try await waitUntil {
            model.selectedItem?.isRead == false
                && model.selectedItem?.isStarred == false
                && model.items.first?.isRead == false
                && model.items.first?.isStarred == false
        }
    }

    func testReadOnlyLibraryModelDoesNotMutateReadingState() async throws {
        let item = makeSummary(id: 43, isRead: false, isStarred: false)
        let gateway = SharedLibraryGatewaySpy(
            page: ContentPage(items: [item], nextCursor: nil),
            snapshot: LibrarySnapshot(
                nodes: [],
                counts: LibraryCountsSnapshot(
                    total: 1, unread: 1,
                    pending: 0, pendingUnread: 0,
                    exported: 0, exportedUnread: 0,
                    articles: 1, articleUnread: 1,
                    podcasts: 0, podcastUnread: 0,
                    videos: 0, videoUnread: 0)))
        let permissions = ReadBoardPermissionSet(
            capabilities: [.library],
            scopes: [.readLibrary])
        let model = ContentViewModel(library: gateway, permissions: permissions)

        model.open(item)
        model.toggleStar(item)
        model.toggleRead(item)
        model.markAllRead()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.selectedItem?.id, item.id)
        XCTAssertFalse(model.canUpdateReadingState)
        let readCalls = await gateway.readCalls()
        let starCalls = await gateway.starCalls()
        XCTAssertTrue(readCalls.isEmpty)
        XCTAssertTrue(starCalls.isEmpty)
        XCTAssertEqual(model.toastMessage, "当前设备只有阅读权限")
    }

    func testArticleRowRelativeDateUsesEpochContract() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(ArticleRow.relativeDate(from: 9_970, now: now), "刚刚")
        XCTAssertEqual(ArticleRow.relativeDate(from: 6_400, now: now), "1 小时前")
    }

    func testSidebarCountFormattingKeepsCoreCompactNotation() {
        XCTAssertEqual(ReadBoardSidebarFormatting.compactCount(9_999), "9999")
        XCTAssertEqual(ReadBoardSidebarFormatting.compactCount(15_000), "1.5万")
        XCTAssertEqual(ReadBoardSidebarFormatting.compactCount(115_869), "12万")
    }

    func testSidebarCatalogSummaryDetectsUniformAndMixedFolderSettings() {
        let first = makeCatalogSource(
            id: 1, interval: 30, fetchMode: .defuddle,
            automatic: false, autoScore: true)
        let second = makeCatalogSource(
            id: 2, interval: 30, fetchMode: .defuddle,
            automatic: false, autoScore: true)

        XCTAssertEqual(
            ReadBoardSidebarCatalogSummary.uniformInterval([first, second]), 30)
        XCTAssertEqual(
            ReadBoardSidebarCatalogSummary.uniformFetchMode([first, second]),
            .init(kind: .manual, mode: .defuddle))
        XCTAssertEqual(
            ReadBoardSidebarCatalogSummary.uniformPolicy([first, second], key: .score), true)

        let mixed = makeCatalogSource(
            id: 3, interval: 60, fetchMode: .feedFull,
            automatic: true, autoScore: false)
        XCTAssertNil(ReadBoardSidebarCatalogSummary.uniformInterval([first, mixed]))
        XCTAssertNil(ReadBoardSidebarCatalogSummary.uniformFetchMode([first, mixed]))
        XCTAssertNil(
            ReadBoardSidebarCatalogSummary.uniformPolicy([first, mixed], key: .score))
    }

    func testSharedSourceCatalogStoreLoadsContractSnapshot() async {
        let source = makeCatalogSource(
            id: 7, interval: 60, fetchMode: .feedFull,
            automatic: true, autoScore: false)
        let gateway = SharedSourceCatalogGatewayStub(snapshot: SourceCatalogSnapshot(
            sources: [source],
            folders: [SourceFolderItem(id: 3, name: "共享文件夹")],
            isSyncing: true,
            lastSyncMessage: "同步中"))
        let store = SourceCatalogStore(gateway: gateway)

        await store.refresh()

        XCTAssertEqual(store.sources.map(\.id), [7])
        XCTAssertEqual(store.folders.map(\.id), [3])
        XCTAssertTrue(store.isSyncing)
        XCTAssertEqual(store.lastSyncMessage, "同步中")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("等待共享列表状态更新超时")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSummary(
        id: Int64,
        isRead: Bool,
        isStarred: Bool
    ) -> ContentSummary {
        ContentSummary(
            id: id,
            contentType: "article",
            source: "rss",
            sourceType: "rss",
            sourceID: 7,
            sourceName: "测试源",
            title: "共享列表测试",
            author: nil,
            url: "https://example.com/42",
            language: "zh",
            publishedAt: 1_786_213_800,
            excerpt: "摘要",
            score: 90,
            summary: "AI 摘要",
            fetchStatus: 1,
            isRead: isRead,
            isStarred: isStarred,
            imageURL: nil,
            hasTranslation: true,
            hasTranscript: false,
            isMedia: false,
            translatedHead: "共享列表测试",
            translatedTitle: "共享列表测试",
            hasFulltext: true,
            hasExport: false,
            hasUnmetProcessing: false,
            accessState: nil)
    }

    private func makeCatalogSource(
        id: Int64,
        interval: Int,
        fetchMode: SourceFetchMode,
        automatic: Bool,
        autoScore: Bool
    ) -> SourceCatalogItem {
        SourceCatalogItem(
            id: id,
            sourceType: "rss",
            name: "源 \(id)",
            identifier: "https://example.com/\(id).xml",
            enabled: true,
            lastFetchedAt: nil,
            error: nil,
            folderID: 3,
            policy: SourcePolicySnapshot(autoScore: autoScore),
            fetchMode: fetchMode,
            fetchModeAutomatic: automatic,
            fetchIntervalMinutes: interval,
            maximumRetainedContent: 0,
            transcribable: false)
    }
}

private actor SharedSourceCatalogGatewayStub: SourceCatalogGateway {
    let snapshotValue: SourceCatalogSnapshot

    init(snapshot: SourceCatalogSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot() async throws -> SourceCatalogSnapshot { snapshotValue }
}

private actor SharedLibraryGatewaySpy: LibraryGateway {
    struct ReadCall: Equatable {
        let contentID: Int64
        let isRead: Bool
    }

    struct StarCall: Equatable {
        let contentID: Int64
        let isStarred: Bool
    }

    private let pageValue: ContentPage
    private let snapshotValue: LibrarySnapshot
    private var recordedReadCalls: [ReadCall] = []
    private var recordedStarCalls: [StarCall] = []

    init(page: ContentPage, snapshot: LibrarySnapshot) {
        pageValue = page
        snapshotValue = snapshot
    }

    func page(_ query: ContentQuery) async throws -> ContentPage { pageValue }
    func snapshot() async throws -> LibrarySnapshot { snapshotValue }

    func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState {
        recordedReadCalls.append(ReadCall(contentID: contentID, isRead: isRead))
        return ContentState(
            contentID: contentID,
            isRead: isRead,
            isStarred: false,
            updatedAt: 1)
    }

    func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState {
        recordedStarCalls.append(StarCall(contentID: contentID, isStarred: isStarred))
        return ContentState(
            contentID: contentID,
            isRead: true,
            isStarred: isStarred,
            updatedAt: 1)
    }

    func markRead(filter: ContentFilter) async throws -> MutationSummary {
        MutationSummary(affectedCount: 1)
    }

    func readCalls() -> [ReadCall] { recordedReadCalls }
    func starCalls() -> [StarCall] { recordedStarCalls }
}

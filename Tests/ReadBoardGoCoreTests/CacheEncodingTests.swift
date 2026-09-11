import Foundation
import CryptoKit
import XCTest
import ReadBoardContract
@testable import ReadBoardGoCore

final class CacheEncodingTests: XCTestCase {
    private struct LegacyRecord<Value: Codable>: Codable {
        let value: Value
        let updatedAt: TimeInterval
    }

    // Decode with the former format, independently of the optimized writer.
    private struct LegacyEnvelope: Codable {
        var serverKey: String?
        var profile: LegacyRecord<RemoteServerProfile>?
        var librarySnapshot: LegacyRecord<LibrarySnapshot>?
        var sourceCatalog: LegacyRecord<SourceCatalogSnapshot>?
        var pages: [String: LegacyRecord<ContentPage>] = [:]
        var details: [String: LegacyRecord<ContentDetail>] = [:]
        var pendingMutations: [String] = []
        var updatedAt: TimeInterval?
        var recoveryNotice: String?
    }

    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-cache-encoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("cache.json")
    }

    private func detail(_ id: Int64, text: String = "sample") -> ContentDetail {
        ContentDetail(id: id, contentMarkdown: text, translatedMarkdown: "译文\n\"引号\"",
            transcriptMarkdown: "transcript", translatedTitle: "标题 🐦", audioURL: "https://example.com/a?x=1&y=2",
            videoID: "video", score: 80, summary: "摘要", playbackRefreshAvailable: true)
    }

    func testSmallUpdatesReuseEncodingWithoutChangingDiskFormatOrContent() async throws {
        let file = try file()
        let profile = RemoteServerProfile(apiVersion: "2", serverName: "Test",
            capabilities: [.library], grantedScopes: RemoteAccessScope.reader, transportSecurity: "tls")
        var original = LegacyEnvelope(serverKey: "credential-a", profile: .init(value: profile, updatedAt: 1))
        for id in Int64(1)...80 {
            original.details[String(id)] = LegacyRecord(value: detail(id), updatedAt: Double(id))
        }
        try JSONEncoder().encode(original).write(to: file, options: .atomic)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        let query = ContentQuery(pageSize: 300)
        await cache.storePage(ContentPage(items: [], nextCursor: "next"), query: query)
        let first = await cache.persistenceEncodingMetrics
        XCTAssertEqual(first.detailEncodes, 80)
        await cache.storeLibrarySnapshot(LibrarySnapshot(nodes: [], counts: .init(
            total: 80, unread: 3, pending: 1, pendingUnread: 1, exported: 2, exportedUnread: 0,
            articles: 80, articleUnread: 3, podcasts: 0, podcastUnread: 0, videos: 0, videoUnread: 0)))
        let repeated = await cache.persistenceEncodingMetrics
        XCTAssertEqual(repeated.detailEncodes, first.detailEncodes, "Navigation must not re-encode all cached bodies")

        let updated = detail(3, text: "# 更新\n\"\\\u{0000}\t🐦\r\n</script>\u{2028}\u{2029}")
        await cache.storeDetail(updated)
        let changed = await cache.persistenceEncodingMetrics
        XCTAssertEqual(changed.detailEncodes, first.detailEncodes + 1)
        let decoded = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.serverKey, original.serverKey)
        XCTAssertEqual(decoded.profile?.value, profile)
        XCTAssertEqual(decoded.details.count, 80)
        XCTAssertEqual(decoded.details["3"]?.value, updated)
        XCTAssertNotEqual(decoded.details["3"]?.updatedAt, 3)
        for id in Int64(1)...80 where id != 3 {
            XCTAssertEqual(decoded.details[String(id)]?.value, original.details[String(id)]?.value)
            XCTAssertEqual(decoded.details[String(id)]?.updatedAt, original.details[String(id)]?.updatedAt)
        }
        XCTAssertEqual(decoded.librarySnapshot?.value.counts.total, 80)
        let restored = ReadBoardGoOfflineCache(fileURL: file)
        let restoredDetail = await restored.detail(contentID: 3)
        let restoredPage = await restored.page(query: query)
        XCTAssertEqual(restoredDetail, updated)
        XCTAssertEqual(restoredPage?.nextCursor, "next")
    }

    func testCompareIncrementalAndFullEncodingWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_COMPARE_CACHE_ENCODING"] == "1" else {
            throw XCTSkip("Encoding timing comparison is opt-in; normal CI asserts correctness, not wall-clock speed")
        }
        let file = try file()
        let baselineFile = file.deletingLastPathComponent().appendingPathComponent("full-encoding.json")
        let markdown = String(repeating: "A paragraph with **bold**, [a link](https://example.com) and Unicode 文字.\n\n", count: 300)
        var baseline = LegacyEnvelope()
        for id in Int64(1)...500 {
            baseline.details[String(id)] = LegacyRecord(value: detail(id, text: markdown), updatedAt: 1)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let initial = try encoder.encode(baseline)
        try initial.write(to: file, options: .atomic)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        for iteration in 0..<7 {
            let changed = detail(1, text: markdown + "iteration \(iteration)")
            baseline.details["1"] = LegacyRecord(value: changed, updatedAt: Date().timeIntervalSince1970)
            func fullEncode() throws -> Int {
                let start = Date()
                try encoder.encode(baseline).write(to: baselineFile, options: .atomic)
                return Int(Date().timeIntervalSince(start) * 1000)
            }
            let fullMilliseconds: Int
            let incrementalMilliseconds: Int
            if iteration % 2 == 0 {
                fullMilliseconds = try fullEncode()
                let start = Date()
                await cache.storeDetail(changed)
                incrementalMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            } else {
                let start = Date()
                await cache.storeDetail(changed)
                incrementalMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
                fullMilliseconds = try fullEncode()
            }
            print("CACHE_AB iteration=\(iteration) bytes=\(initial.count) full_ms=\(fullMilliseconds) incremental_ms=\(incrementalMilliseconds)")
            let disk = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: file))
            XCTAssertEqual(disk.details["1"]?.value, changed)
            XCTAssertEqual(disk.details.count, 500)
        }
        let metrics = await cache.persistenceEncodingMetrics
        XCTAssertEqual(metrics.detailEncodes, 506)
    }

    func testEncodingCacheCannotMixMatchingIDsAcrossCredentials() async throws {
        let file = try file()
        var first = LegacyEnvelope(serverKey: "account-a")
        first.details["1"] = .init(value: detail(1, text: "account-a body"), updatedAt: 42)
        first.updatedAt = 42
        var second = LegacyEnvelope(serverKey: "account-b")
        second.details["1"] = .init(value: detail(1, text: "account-b body"), updatedAt: 42)
        second.updatedAt = 42
        try JSONEncoder().encode(first).write(to: file, options: .atomic)
        let hash = SHA256.hash(data: Data("account-b".utf8)).map { String(format: "%02x", $0) }.joined()
        let archived = file.deletingLastPathComponent().appendingPathComponent("cache-\(hash).json")
        try JSONEncoder().encode(second).write(to: archived, options: .atomic)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        await cache.storePage(ContentPage(items: [], nextCursor: nil), query: ContentQuery())
        // Deliberately match both ID and timestamp across the two identities.
        // A writer that only checks those two fields would leak account A here.
        try await cache.activate(serverKey: "account-b")
        let active = await cache.detail(contentID: 1)
        XCTAssertEqual(active?.contentMarkdown, "account-b body")
        var disk = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: file))
        XCTAssertEqual(disk.details["1"]?.value.contentMarkdown, "account-b body")
        try await cache.activate(serverKey: "account-a")
        let restored = await cache.detail(contentID: 1)
        XCTAssertEqual(restored?.contentMarkdown, "account-a body")
        disk = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: file))
        XCTAssertEqual(disk.serverKey, "account-a")
        XCTAssertEqual(disk.details["1"]?.value.contentMarkdown, "account-a body")
    }

    func testAdditionalEncodingMemoryIsBoundedAndLargeContentIsNotDropped() async throws {
        let file = try file()
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        let large = detail(1, text: String(repeating: "x", count: 33 * 1_024 * 1_024))
        await cache.storeDetail(large)
        let largeMetrics = await cache.persistenceEncodingMetrics
        XCTAssertEqual(largeMetrics.retainedDetailBytes, 0, "Over-budget entries use normal encoding, not unbounded retention")
        await cache.storeDetail(detail(2))
        let smallMetrics = await cache.persistenceEncodingMetrics
        XCTAssertGreaterThan(smallMetrics.retainedDetailBytes, 0)
        XCTAssertLessThanOrEqual(smallMetrics.retainedDetailBytes, 32 * 1_024 * 1_024)
        let restored = ReadBoardGoOfflineCache(fileURL: file)
        let actual = await restored.detail(contentID: 1)
        XCTAssertEqual(actual, large)
    }

    func testTrimmedArticleIsRemovedFromDiskAndEncodingCache() async throws {
        let file = try file()
        var original = LegacyEnvelope()
        for id in Int64(1)...500 {
            original.details[String(id)] = LegacyRecord(value: detail(id), updatedAt: Double(id))
        }
        try JSONEncoder().encode(original).write(to: file, options: .atomic)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        await cache.storePage(ContentPage(items: [], nextCursor: nil), query: ContentQuery())
        let before = await cache.persistenceEncodingMetrics
        await cache.storeDetail(detail(501))
        let after = await cache.persistenceEncodingMetrics
        XCTAssertEqual(after.detailEncodes, before.detailEncodes + 1)
        let disk = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: file))
        XCTAssertEqual(disk.details.count, 500)
        XCTAssertNil(disk.details["1"])
        XCTAssertEqual(disk.details["501"]?.value, detail(501))
        // Removed members must not continue occupying the encoding budget.
        let rebuilt = ReadBoardGoOfflineCache(fileURL: file)
        await rebuilt.storePage(ContentPage(items: [], nextCursor: nil), query: ContentQuery())
        let rebuiltMetrics = await rebuilt.persistenceEncodingMetrics
        XCTAssertEqual(after.retainedDetailBytes, rebuiltMetrics.retainedDetailBytes)
    }
}

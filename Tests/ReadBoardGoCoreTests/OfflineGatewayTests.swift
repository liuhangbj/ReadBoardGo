import Foundation
import XCTest
import ReadBoardContract
import ReadBoardRemote
@testable import ReadBoardGoCore

final class OfflineGatewayTests: XCTestCase {
    func testFailedOfflinePersistenceRollsBackAndCanRetryAfterStorageRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-offline-write-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let query = ContentQuery()
        let item = ContentSummary(id: 1, contentType: "article", source: "web",
            sourceType: nil, sourceID: nil, sourceName: nil, title: "Isolated sample",
            author: nil, url: "https://example.com/1", language: nil, publishedAt: nil,
            excerpt: nil, score: nil, summary: nil, fetchStatus: 2, isRead: false,
            isStarred: false, imageURL: nil, hasTranslation: false, hasTranscript: false,
            isMedia: false, translatedHead: nil, translatedTitle: nil, hasFulltext: true,
            hasExport: false, hasUnmetProcessing: false, accessState: nil)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        try await cache.activate(serverKey: "isolated-failure-credential")
        await cache.storePage(ContentPage(items: [item], nextCursor: nil), query: query)
        let originalData = try Data(contentsOf: file)
        // A directory at the exact file path deterministically rejects atomic
        // writes, without relying on the test process's permission privileges.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await cache.setTransportOffline(true)
        let transport = OfflineFixtureTransport()
        let client = ReadBoardHTTPClient(baseURL: URL(string: "https://isolated.invalid")!,
            bearerToken: "isolated-token", loader: transport)
        let gateway = CachedRemoteLibraryGateway(client: client, cache: cache,
            serverKey: "isolated-failure-credential")
        do {
            _ = try await gateway.setRead(contentID: 1, isRead: true)
            XCTFail("An offline operation must not succeed when durable storage fails")
        } catch let error as LibraryGatewayError {
            XCTAssertEqual(error, .operationFailed("无法保存离线操作，请检查本机存储空间后重试。"))
        }
        let failedStatus = await cache.status()
        let failedPage = await cache.page(query: query)
        XCTAssertEqual(failedStatus.pendingReadingMutations, 0)
        XCTAssertEqual(failedPage?.items.first?.isRead, false)
        try FileManager.default.removeItem(at: file)
        try originalData.write(to: file, options: .atomic)
        _ = try await gateway.setRead(contentID: 1, isRead: true)
        let restarted = ReadBoardGoOfflineCache(fileURL: file)
        let finalPage = await restarted.page(query: query)
        let finalStatus = await restarted.status()
        XCTAssertEqual(finalPage?.items.first?.isRead, true)
        XCTAssertEqual(finalStatus.pendingReadingMutations, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests, 0)
    }

    func testSocialInboxWritesPersistAcrossRestartAndFlushThroughRemoteContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-offline-gateway-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let query = ContentQuery(filter: ContentFilter(category: .video,
            sourceFamily: .social, inboxOnly: true))
        let item = ContentSummary(id: 101, contentType: "video", source: "douyin",
            sourceType: "douyin", sourceID: nil, sourceName: nil, title: "Isolated sample",
            author: nil, url: "https://example.com/101", language: nil, publishedAt: nil,
            excerpt: nil, score: nil, summary: nil, fetchStatus: 2, isRead: false,
            isStarred: false, imageURL: nil, hasTranslation: false, hasTranscript: false,
            isMedia: true, translatedHead: nil, translatedTitle: nil, hasFulltext: true,
            hasExport: false, hasUnmetProcessing: false, accessState: nil)
        let cache = ReadBoardGoOfflineCache(fileURL: file)
        try await cache.activate(serverKey: "isolated-credential")
        await cache.storePage(ContentPage(items: [item], nextCursor: nil), query: query)
        await cache.setTransportOffline(true)
        let transport = OfflineFixtureTransport()
        let client = ReadBoardHTTPClient(baseURL: URL(string: "https://isolated.invalid")!,
            bearerToken: "isolated-token", loader: transport)
        let gateway = CachedRemoteLibraryGateway(client: client, cache: cache)
        let retiredGateway = CachedRemoteLibraryGateway(client: client, cache: cache,
            serverKey: "retired-credential")
        do {
            _ = try await retiredGateway.page(query)
            XCTFail("A retired gateway must not read another credential's cached page")
        } catch is CancellationError { } catch {
            XCTFail("Identity rejection should cancel the retired request: \(error)")
        }
        _ = try await gateway.setRead(contentID: 101, isRead: true)
        _ = try await gateway.setStarred(contentID: 101, isStarred: true)
        do {
            _ = try await gateway.markRead(filter: query.filter)
            XCTFail("Offline bulk mark read must remain forbidden")
        } catch { }
        let status = await cache.status()
        XCTAssertEqual(status.pendingReadingMutations, 2)
        let offlineRequests = await transport.requests
        XCTAssertEqual(offlineRequests, 0, "Known-offline cache access must not wait on transport")
        let restored = ReadBoardGoOfflineCache(fileURL: file)
        try await restored.activate(serverKey: "another-credential")
        let otherStatus = await restored.status()
        XCTAssertEqual(otherStatus.pendingReadingMutations, 0)
        XCTAssertNotNil(otherStatus.recoveryNotice)
        let otherPage = await restored.page(query: query)
        XCTAssertNil(otherPage)
        try await restored.activate(serverKey: "isolated-credential")
        let archivedStatus = await restored.status()
        XCTAssertEqual(archivedStatus.pendingReadingMutations, 2)
        let restoredGateway = CachedRemoteLibraryGateway(client: client, cache: restored)
        for error in [ReadBoardGoConnectionError.connectionFailed, .secureConnectionFailed] {
            await transport.setFailure(error)
            let typedFallback = try await restoredGateway.page(query)
            XCTAssertEqual(typedFallback.items.count, 1)
        }
        await transport.setFailure(.certificateNotTrusted)
        do {
            _ = try await restoredGateway.page(query)
            XCTFail("A pin mismatch must not fall back to cached data")
        } catch let error as ReadBoardGoConnectionError {
            guard case .certificateNotTrusted = error else {
                return XCTFail("Expected pin rejection, got \(error)")
            }
        }
        await transport.setFailure(nil)
        let page = try await restoredGateway.page(query)
        XCTAssertTrue(page.items[0].isRead)
        XCTAssertTrue(page.items[0].isStarred)
        await transport.setOnline()
        // Snapshot itself deliberately fails after the flush. This confirms
        // writes still pass through the real RemoteLibraryGateway contract.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask { _ = try? await restoredGateway.snapshot() }
            }
        }
        let flushed = await restored.status()
        XCTAssertEqual(flushed.pendingReadingMutations, 0)
        let writes = await transport.writes
        XCTAssertEqual(writes, ["/api/v1/library/read", "/api/v1/library/star"])
        let secondRestart = ReadBoardGoOfflineCache(fileURL: file)
        let finalPage = await secondRestart.page(query: query)
        let final = try XCTUnwrap(finalPage).items[0]
        XCTAssertTrue(final.isRead)
        XCTAssertTrue(final.isStarred)
        // A fresh online choice follows older offline targets through the same
        // serialized mutation path and remains authoritative after restart.
        await transport.setOffline()
        _ = try await restoredGateway.setRead(contentID: 101, isRead: true)
        await transport.setOnline()
        _ = try await restoredGateway.setRead(contentID: 101, isRead: false)
        let newest = ReadBoardGoOfflineCache(fileURL: file)
        let newestPage = await newest.page(query: query)
        XCTAssertEqual(newestPage?.items.first?.isRead, false)
        let finalServerRead = await transport.read
        XCTAssertFalse(finalServerRead)
    }
}

private actor OfflineFixtureTransport: RemoteRequestLoading {
    var online = false
    var read = false
    var starred = false
    var writes: [String] = []
    var requests = 0
    var failure: ReadBoardGoConnectionError?
    func setFailure(_ error: ReadBoardGoConnectionError?) { failure = error }
    func setOnline() { online = true }
    func setOffline() { online = false }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if let failure { throw failure }
        guard online else { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        guard path == "/api/v1/library/read" || path == "/api/v1/library/star" else {
            throw URLError(.networkConnectionLost)
        }
        let input = try JSONDecoder().decode(RemoteContentStateRequest.self, from: request.httpBody!)
        writes.append(path)
        if path.hasSuffix("/read") { read = input.value } else { starred = input.value }
        let state = ContentState(contentID: input.contentID, isRead: read,
                                 isStarred: starred, updatedAt: 1)
        return (try JSONEncoder().encode(state), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: [ReadBoardRemoteAPI.versionHeader: ReadBoardRemoteAPI.version])!)
    }
}

import Foundation
import XCTest
import ReadBoardContract
import ReadBoardRemote
@testable import ReadBoardGoCore

/// Actual TLS, session monitoring and durable cache against Core's opt-in host.
/// This must never load a production connection or operate the port 7331 service.
@MainActor
final class LiveSessionRecoveryTests: XCTestCase {
    func testStoppedServerRestoresSessionAndFlushesDurableReadingStateWhenEnabled() async throws {
        guard let raw = ProcessInfo.processInfo.environment["READBOARD_RECOVERY_FIXTURE"] else {
            throw XCTSkip("Requires Core's separate isolated recovery host")
        }
        let root = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix("readboard-recovery-") else {
            return XCTFail("Only the explicit temporary recovery fixture is allowed")
        }
        let store = FileConnectionStore(fileURL: root.appendingPathComponent("connection.json"))
        let stored = try XCTUnwrap(store.load())
        guard stored.baseURL.scheme == "https", stored.baseURL.host == "127.0.0.1",
              let port = stored.baseURL.port, port > 0, port != 7331 else {
            return XCTFail("Refusing to stop or modify a non-fixture server")
        }
        let suite = "readboard-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cacheURL = root.appendingPathComponent("cache.json")
        let cache = ReadBoardGoOfflineCache(fileURL: cacheURL)
        let session = ReadBoardGoSession(store: store, offlineCache: cache, pendingInboxDefaults: defaults)
        await session.refreshProfile()
        XCTAssertTrue(session.isConnected)
        XCTAssertFalse(session.isOffline)
        let environment = try session.featureEnvironment()
        let query = ContentQuery(filter: .init(inboxOnly: true))
        let page = try await environment.library.page(query)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.id, 9_311_901)
        XCTAssertFalse(item.isRead)
        let detail = try await environment.contentDetail.detail(contentID: item.id)
        let snapshot = try await environment.library.snapshot()
        XCTAssertEqual(snapshot.counts.unread, 1)

        let monitor = Task { await session.monitorConnection() }
        defer { monitor.cancel() }
        try command("stop", root: root)
        try await waitUntil("host stopped", seconds: 5) { status(root) == "offline" }
        // No direct refreshProfile or cache offline flag: exercise the same
        // periodic monitor started by the shipping App shell.
        try await waitUntil("session automatically offline", seconds: 60) { session.isOffline }
        XCTAssertTrue(session.isConnected, "Known cache must keep the reader mounted")
        let offlinePage = try await environment.library.page(query)
        let offlineDetail = try await environment.contentDetail.detail(contentID: item.id)
        XCTAssertEqual(offlinePage, page)
        XCTAssertEqual(offlineDetail, detail)
        _ = try await environment.library.setRead(contentID: item.id, isRead: true)
        _ = try await environment.library.setStarred(contentID: item.id, isStarred: true)
        let offlineCounts = try await environment.library.snapshot()
        XCTAssertEqual(offlineCounts.counts.unread, 0)
        XCTAssertEqual(offlineCounts.counts.inboxUnread, 0)
        let pending = await cache.status()
        XCTAssertEqual(pending.pendingReadingMutations, 2)
        monitor.cancel()
        await monitor.value

        let restartedCache = ReadBoardGoOfflineCache(fileURL: cacheURL)
        let restarted = ReadBoardGoSession(store: store, offlineCache: restartedCache,
            pendingInboxDefaults: defaults)
        await restarted.refreshProfile()
        XCTAssertTrue(restarted.isConnected)
        XCTAssertTrue(restarted.isOffline)
        let restoredEnvironment = try restarted.featureEnvironment()
        let restoredPage = try await restoredEnvironment.library.page(query)
        XCTAssertTrue(try XCTUnwrap(restoredPage.items.first).isRead)
        XCTAssertTrue(try XCTUnwrap(restoredPage.items.first).isStarred)
        let restoredDetail = try await restoredEnvironment.contentDetail.detail(contentID: item.id)
        XCTAssertEqual(restoredDetail, detail)
        let secondMonitor = Task { await restarted.monitorConnection() }
        defer { secondMonitor.cancel() }
        try command("restart", root: root)
        try await waitUntil("host resumed", seconds: 5) { status(root) == "online" }
        try await waitUntil("session automatically online", seconds: 45) {
            guard restarted.isConnected, !restarted.isOffline else { return false }
            let status = await restartedCache.status()
            return status.pendingReadingMutations == 0
        }
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(restarted.connection?.certificateFingerprint, stored.certificateFingerprint)
        XCTAssertEqual(restarted.connection?.token, stored.token)
        let client = ReadBoardHTTPClient(baseURL: stored.baseURL, bearerToken: stored.token,
            loader: PinnedHTTPS.client(baseURL: stored.baseURL,
                certificateFingerprint: try XCTUnwrap(stored.certificateFingerprint)))
        let authoritative = RemoteLibraryGateway(client: client)
        let finalPage = try await authoritative.page(query)
        let finalItem = try XCTUnwrap(finalPage.items.first)
        XCTAssertTrue(finalItem.isRead)
        XCTAssertTrue(finalItem.isStarred)
        let finalSnapshot = try await authoritative.snapshot()
        XCTAssertEqual(finalSnapshot.counts.unread, 0)
        XCTAssertEqual(finalSnapshot.counts.total, 1)
        let reread = try await restoredEnvironment.library.page(query)
        XCTAssertEqual(reread, finalPage)
        // No queued replay after another disk-cache reconstruction.
        let finalCache = ReadBoardGoOfflineCache(fileURL: cacheURL)
        let finalStatus = await finalCache.status()
        XCTAssertEqual(finalStatus.pendingReadingMutations, 0)
        let finalCached = await finalCache.page(query: query)
        XCTAssertEqual(finalCached, finalPage)
        secondMonitor.cancel()
        await secondMonitor.value
        try command("finish", root: root)
        try await waitUntil("host verified final database", seconds: 5) { status(root) == "finished" }
        print("RECOVERY real TLS stop/restart, retained reader, cache restart and authoritative flush passed")
    }

    private func command(_ value: String, root: URL) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent("command"), options: .atomic)
    }

    private func status(_ root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent("status"), encoding: .utf8)
    }

    private func waitUntil(_ description: String, seconds: Int,
                           condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out: \(description)")
        throw RecoveryTestError.deadline
    }
}

private enum RecoveryTestError: Error { case deadline }

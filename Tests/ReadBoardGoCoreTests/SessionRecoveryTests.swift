import Foundation
import XCTest
import ReadBoardContract
import ReadBoardRemote
@testable import ReadBoardGoCore

@MainActor
final class SessionRecoveryTests: XCTestCase {
    private func connection(token: String = "isolated-test-token") -> StoredServerConnection {
        StoredServerConnection(baseURL: URL(string: "https://127.0.0.1:49999")!,
            credential: RemotePairingCredential(deviceID: "test", deviceName: "test",
                token: token, apiVersion: ReadBoardRemoteAPI.version, scopes: RemoteAccessScope.reader),
            certificateFingerprint: String(repeating: "a", count: 64))
    }

    private func profile() -> RemoteServerProfile {
        .init(apiVersion: ReadBoardRemoteAPI.version, serverName: "isolated",
              capabilities: [.library], grantedScopes: RemoteAccessScope.reader, transportSecurity: "tls")
    }

    private func environment() throws -> (ReadBoardGoOfflineCache, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-session-test-\(UUID().uuidString)")
        let suite = "readboard-session-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (ReadBoardGoOfflineCache(fileURL: directory.appendingPathComponent("cache.json")), defaults)
    }

    func testProfileFailureKeepsCachedReadingThenRecovers() async throws {
        let (cache, defaults) = try environment()
        let expected = profile()
        let probe = RecoveryProbe(profile: expected)
        let session = ReadBoardGoSession(store: RecoveryStore(value: connection()),
            offlineCache: cache, pendingInboxDefaults: defaults,
            profileLoader: { _ in try await probe.load() })
        await session.refreshProfile()
        XCTAssertTrue(session.isConnected)
        XCTAssertFalse(session.isOffline)
        await probe.fail()
        await session.refreshProfile(showProgress: false)
        XCTAssertTrue(session.isConnected)
        XCTAssertTrue(session.isOffline)
        XCTAssertEqual(session.profile, expected)
        await probe.recover()
        await session.refreshProfile(showProgress: false)
        XCTAssertTrue(session.isConnected)
        XCTAssertFalse(session.isOffline)
        XCTAssertNil(session.errorMessage)
    }

    func testSavedProfileOpensCacheBeforeLiveProbeFinishes() async throws {
        let (cache, defaults) = try environment()
        try await cache.activate(serverKey: connection().cacheIdentity)
        await cache.storeProfile(profile())
        let probe = SuspendedProbe()
        let session = ReadBoardGoSession(store: RecoveryStore(value: connection()),
            offlineCache: cache, pendingInboxDefaults: defaults,
            profileLoader: { _ in await probe.load() })
        let refresh = Task { await session.refreshProfile() }
        while !(await probe.started) { await Task.yield() }
        XCTAssertTrue(session.isConnected)
        XCTAssertTrue(session.isOffline)
        XCTAssertFalse(session.isRestoringConnection)
        await probe.finish(profile())
        await refresh.value
        XCTAssertFalse(session.isOffline)
    }

    func testLateProfileCannotReconnectAfterUserDisconnects() async throws {
        let (cache, defaults) = try environment()
        let probe = SuspendedProbe()
        let session = ReadBoardGoSession(store: RecoveryStore(value: connection()),
            offlineCache: cache, pendingInboxDefaults: defaults,
            profileLoader: { _ in await probe.load() })
        let refresh = Task { await session.refreshProfile() }
        while !(await probe.started) { await Task.yield() }
        session.disconnect()
        await probe.finish(profile())
        await refresh.value
        XCTAssertNil(session.connection)
        XCTAssertNil(session.profile)
        XCTAssertFalse(session.isConnected)
        let persisted = await cache.profile()
        XCTAssertNil(persisted)
    }

    func testSameServerDifferentCredentialsCannotReuseOfflineData() async throws {
        let (cache, _) = try environment()
        let first = connection(), second = connection(token: "other-test-token")
        XCTAssertNotEqual(first.cacheIdentity, second.cacheIdentity)
        XCTAssertFalse(first.cacheIdentity.contains(first.token))
        XCTAssertEqual(first.cacheIdentity,
            StoredServerConnection(copying: first, apiVersion: "future").cacheIdentity)
        try await cache.activate(serverKey: first.cacheIdentity)
        await cache.storeProfile(profile())
        try await cache.activate(serverKey: second.cacheIdentity)
        let persisted = await cache.profile()
        XCTAssertNil(persisted)
        try await cache.activate(serverKey: first.cacheIdentity)
        let restored = await cache.profile()
        XCTAssertEqual(restored, profile())
    }

    func testCertificateFailureDoesNotAuthorizeCachedSession() async throws {
        let (cache, defaults) = try environment()
        try await cache.activate(serverKey: connection().cacheIdentity)
        await cache.storeProfile(profile())
        let session = ReadBoardGoSession(store: RecoveryStore(value: connection()),
            offlineCache: cache, pendingInboxDefaults: defaults,
            profileLoader: { _ in throw URLError(.serverCertificateUntrusted) })
        await session.refreshProfile()
        XCTAssertFalse(session.isConnected)
        XCTAssertFalse(session.isOffline)
        XCTAssertNil(session.profile)
        XCTAssertNotNil(session.errorMessage)
    }
}

private struct RecoveryStore: ConnectionStoring {
    let value: StoredServerConnection
    func load() throws -> StoredServerConnection? { value }
    func save(_ connection: StoredServerConnection) throws {}
    func delete() throws {}
}

private actor RecoveryProbe {
    let profile: RemoteServerProfile
    var failing = false
    init(profile: RemoteServerProfile) { self.profile = profile }
    func fail() { failing = true }
    func recover() { failing = false }
    func load() throws -> RemoteServerProfile {
        if failing { throw URLError(.cannotConnectToHost) }
        return profile
    }
}

private actor SuspendedProbe {
    var started = false
    var continuation: CheckedContinuation<RemoteServerProfile, Never>?
    func load() async -> RemoteServerProfile {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func finish(_ profile: RemoteServerProfile) { continuation?.resume(returning: profile) }
}

import Foundation
import Observation
import ReadBoardContract
import ReadBoardFeatures
import ReadBoardRemote

@MainActor
@Observable
public final class ReadBoardGoSession {
    public private(set) var connection: StoredServerConnection?
    public private(set) var profile: RemoteServerProfile?
    public private(set) var isWorking = false
    public private(set) var isRestoringConnection = false
    public private(set) var errorMessage: String?
    public private(set) var trustCandidate: ServerTrustCandidate?
    public let discovery = ReadBoardDiscovery()
    public let remoteHealth = ReadBoardRemoteHealthStore()

    private let store: any ConnectionStoring

    public init(store: any ConnectionStoring = DefaultConnectionStore()) {
        self.store = store
        do {
            let stored = try store.load()
            if let stored, stored.baseURL.scheme == "https",
               stored.certificateFingerprint != nil {
                if let version = stored.apiVersion,
                   version != ReadBoardRemoteAPI.version {
                    try store.delete()
                    errorMessage = ReadBoardGoConnectionError.apiVersionMismatch(
                        client: ReadBoardRemoteAPI.version,
                        server: version).localizedDescription
                } else {
                    connection = stored
                    isRestoringConnection = true
                }
            } else if stored != nil {
                try store.delete()
                errorMessage = "服务端已升级为 HTTPS，请重新登录一次"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var isConnected: Bool {
        connection != nil && profile?.apiVersion == ReadBoardRemoteAPI.version
    }

    public func hasScope(_ scope: RemoteAccessScope) -> Bool {
        profile?.grantedScopes.contains(scope) ?? connection?.scopes.contains(scope) ?? false
    }

    public func hasCapability(_ capability: RemoteServiceCapability) -> Bool {
        profile?.capabilities.contains(capability) ?? false
    }

    public func select(_ server: DiscoveredReadBoardServer) {
        guard let baseURL = server.baseURLs.first else { return }
        trustCandidate = ServerTrustCandidate(name: server.name, baseURL: baseURL,
            certificateFingerprint: server.certificateFingerprint)
        errorMessage = nil
    }

    public func inspectServer(address: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let baseURL = try ServerAddressNormalizer.normalize(address)
            let fingerprint = try await PinnedHTTPS.inspectCertificate(at: baseURL)
            trustCandidate = ServerTrustCandidate(name: baseURL.host ?? "ReadBoard",
                baseURL: baseURL, certificateFingerprint: fingerprint)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelTrustCandidate() {
        trustCandidate = nil
        errorMessage = nil
    }

    public func login(password: String, deviceName: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            guard let trustCandidate else {
                throw ReadBoardGoConnectionError.certificateNotTrusted
            }
            let session = PinnedHTTPS.session(
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let credential = try await RemotePasswordLoginClient.login(
                baseURL: trustCandidate.baseURL, password: password,
                deviceName: deviceName, session: session)
            try validateAPIVersion(credential.apiVersion)
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, session: session).profile()
            try validateAPIVersion(profile.apiVersion)
            try store.save(value)
            connection = value
            self.profile = profile
            self.trustCandidate = nil
            discovery.stop()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pair(code: String, deviceName: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            guard let trustCandidate else {
                throw ReadBoardGoConnectionError.certificateNotTrusted
            }
            let pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pairingCode.isEmpty else { throw ReadBoardGoConnectionError.emptyPairingCode }
            let session = PinnedHTTPS.session(
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let credential = try await RemotePairingClient.pair(
                baseURL: trustCandidate.baseURL, code: pairingCode,
                deviceName: deviceName, session: session)
            try validateAPIVersion(credential.apiVersion)
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, session: session).profile()
            try validateAPIVersion(profile.apiVersion)
            try store.save(value)
            connection = value
            self.profile = profile
            self.trustCandidate = nil
            discovery.stop()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshProfile() async {
        guard let connection else { return }
        isRestoringConnection = true
        defer { isRestoringConnection = false }
        do {
            let loaded = try await client(for: connection).profile()
            try validateAPIVersion(loaded.apiVersion)
            profile = loaded
            remoteHealth.reset()
            let upgraded = StoredServerConnection(
                copying: connection,
                apiVersion: loaded.apiVersion)
            try store.save(upgraded)
            self.connection = upgraded
            errorMessage = nil
        } catch {
            profile = nil
            if let connectionError = error as? ReadBoardGoConnectionError,
               case .apiVersionMismatch = connectionError {
                try? store.delete()
                self.connection = nil
                remoteHealth.receive(.failed(
                    path: "api/v1/server/profile",
                    kind: .version,
                    message: error.localizedDescription))
            }
            errorMessage = error.localizedDescription
        }
    }

    public func disconnect() {
        do { try store.delete() } catch { errorMessage = error.localizedDescription }
        connection = nil
        profile = nil
        trustCandidate = nil
        isRestoringConnection = false
        remoteHealth.reset()
    }

    public func libraryPage(_ query: ContentQuery = ContentQuery()) async throws -> ContentPage {
        try await RemoteLibraryGateway(client: try client()).page(query)
    }

    public func librarySnapshot() async throws -> LibrarySnapshot {
        try await RemoteLibraryGateway(client: try client()).snapshot()
    }

    public func contentDetail(id: Int64) async throws -> ContentDetail {
        try await RemoteContentDetailGateway(client: try client()).detail(contentID: id)
    }

    public func youtubeStream(videoID: String) async throws -> MediaPlaybackSource {
        try await RemoteMediaPlaybackGateway(client: try client())
            .youtubeStream(videoID: videoID)
    }

    public func setRead(id: Int64, value: Bool) async throws -> ContentState {
        try await RemoteLibraryGateway(client: try client()).setRead(contentID: id, isRead: value)
    }

    public func setStarred(id: Int64, value: Bool) async throws -> ContentState {
        try await RemoteLibraryGateway(client: try client())
            .setStarred(contentID: id, isStarred: value)
    }

    public func sourceCatalog() async throws -> SourceCatalogSnapshot {
        try await RemoteSourceCatalogGateway(client: try client()).snapshot()
    }

    public func runtimeStatus() async -> RuntimeStatusSnapshot {
        guard let client = try? client() else { return RuntimeStatusSnapshot() }
        return await RemoteRuntimeStatusGateway(client: client).snapshot(refreshCounts: true)
    }

    public func runProcessingScan() async {
        guard let client = try? client() else { return }
        await RemoteRuntimeStatusGateway(client: client).runProcessingScan()
    }

    public func authenticationStatuses() async -> [PlatformAuthenticationStatus] {
        guard let client = try? client() else { return [] }
        return await RemoteAuthenticationGateway(client: client).statuses()
    }

    /// Go 与 Core 共同页面的远程装配入口。共享页面无需知道 HTTP、证书或登录态细节。
    public func featureEnvironment() throws -> ReadBoardFeatureEnvironment {
        let client = try client()
        return ReadBoardFeatureEnvironment(
            library: RemoteLibraryGateway(client: client),
            contentDetail: RemoteContentDetailGateway(client: client),
            mediaPlayback: RemoteMediaPlaybackGateway(client: client),
            processing: RemoteProcessingGateway(client: client),
            sourceManagement: RemoteSourceManagementGateway(client: client),
            sourceCatalog: RemoteSourceCatalogGateway(client: client),
            sourceOnboarding: RemoteSourceOnboardingGateway(client: client),
            runtimeStatus: RemoteRuntimeStatusGateway(client: client),
            export: RemoteExportGateway(client: client),
            administration: RemoteAdministrationGateway(client: client),
            configuration: RemoteConfigurationGateway(client: client),
            authentication: RemoteAuthenticationGateway(client: client),
            maintenance: RemoteMaintenanceGateway(client: client),
            permissions: ReadBoardFeaturePermissions(
                capabilities: profile?.capabilities ?? [],
                scopes: profile?.grantedScopes ?? connection?.scopes ?? []))
    }

    /// 完整 Core 前端快照装配远程 gateway 时使用。客户端仍由会话统一创建，
    /// 证书固定、令牌和超时策略不会在 App 层重复实现。
    public func remoteClient() throws -> ReadBoardHTTPClient {
        try client()
    }

    private func client() throws -> ReadBoardHTTPClient {
        guard let connection else { throw ReadBoardGoConnectionError.notConnected }
        return client(for: connection)
    }

    private func client(for connection: StoredServerConnection) -> ReadBoardHTTPClient {
        let fingerprint = connection.certificateFingerprint ?? ""
        return ReadBoardHTTPClient(baseURL: connection.baseURL,
            bearerToken: connection.token,
            session: PinnedHTTPS.session(certificateFingerprint: fingerprint),
            eventHandler: { [weak remoteHealth] event in
                Task { @MainActor in
                    remoteHealth?.receive(event)
                }
            })
    }

    private func validateAPIVersion(_ serverVersion: String) throws {
        guard serverVersion == ReadBoardRemoteAPI.version else {
            throw ReadBoardGoConnectionError.apiVersionMismatch(
                client: ReadBoardRemoteAPI.version,
                server: serverVersion)
        }
    }
}

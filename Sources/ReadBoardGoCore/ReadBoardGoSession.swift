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
    public private(set) var isOffline = false
    public private(set) var cachedAt: Date?
    public private(set) var pendingInboxImportCount = 0
    public let discovery = ReadBoardDiscovery()
    public let remoteHealth = ReadBoardRemoteHealthStore()

    private let store: any ConnectionStoring
    private let offlineCache: ReadBoardGoOfflineCache
    private let pendingInboxStore: PendingInboxImportStore
    private let certificateInspector: @Sendable (URL) async throws -> String
    private var isFlushingInboxImports = false
    private var serverInspectionID: UUID?

    public init(
        store: any ConnectionStoring = DefaultConnectionStore(),
        offlineCache: ReadBoardGoOfflineCache = ReadBoardGoOfflineCache(),
        certificateInspector: @escaping @Sendable (URL) async throws -> String = {
            try await PinnedHTTPS.inspectCertificate(at: $0)
        }
    ) {
        self.store = store
        self.offlineCache = offlineCache
        self.pendingInboxStore = PendingInboxImportStore()
        self.certificateInspector = certificateInspector
        self.pendingInboxImportCount = pendingInboxStore.load().count
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
        serverInspectionID = nil
        isWorking = false
        trustCandidate = ServerTrustCandidate(name: server.name, baseURL: baseURL,
            certificateFingerprint: server.certificateFingerprint)
        errorMessage = nil
    }

    public func inspectServer(address: String) async {
        let inspectionID = UUID()
        serverInspectionID = inspectionID
        isWorking = true
        errorMessage = nil
        defer {
            if serverInspectionID == inspectionID {
                serverInspectionID = nil
                isWorking = false
            }
        }
        do {
            let baseURL = try ServerAddressNormalizer.normalize(address)
            let fingerprint = try await certificateInspector(baseURL)
            guard serverInspectionID == inspectionID, !Task.isCancelled else { return }
            trustCandidate = ServerTrustCandidate(name: baseURL.host ?? "ReadBoard",
                baseURL: baseURL, certificateFingerprint: fingerprint)
        } catch is CancellationError {
            return
        } catch {
            guard serverInspectionID == inspectionID else { return }
            errorMessage = ReadBoardGoConnectionError.userFacingDescription(for: error)
        }
    }

    public func cancelTrustCandidate() {
        serverInspectionID = nil
        isWorking = false
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
            let loader = PinnedHTTPS.client(
                baseURL: trustCandidate.baseURL,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let credential = try await RemotePasswordLoginClient.login(
                baseURL: trustCandidate.baseURL, password: password,
                deviceName: deviceName, loader: loader)
            try validateAPIVersion(credential.apiVersion)
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, loader: loader).profile()
            try validateAPIVersion(profile.apiVersion)
            try store.save(value)
            connection = value
            self.profile = profile
            await offlineCache.activate(serverKey: cacheServerKey(value))
            await offlineCache.storeProfile(profile)
            isOffline = false
            self.trustCandidate = nil
            discovery.stop()
            await flushPendingInboxImports()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReadBoardGoConnectionError.userFacingDescription(
                for: error, certificateWasPinned: true)
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
            let loader = PinnedHTTPS.client(
                baseURL: trustCandidate.baseURL,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let credential = try await RemotePairingClient.pair(
                baseURL: trustCandidate.baseURL, code: pairingCode,
                deviceName: deviceName, loader: loader)
            try validateAPIVersion(credential.apiVersion)
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, loader: loader).profile()
            try validateAPIVersion(profile.apiVersion)
            try store.save(value)
            connection = value
            self.profile = profile
            await offlineCache.activate(serverKey: cacheServerKey(value))
            await offlineCache.storeProfile(profile)
            isOffline = false
            self.trustCandidate = nil
            discovery.stop()
            await flushPendingInboxImports()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReadBoardGoConnectionError.userFacingDescription(
                for: error, certificateWasPinned: true)
        }
    }

    public func refreshProfile(showProgress: Bool = true) async {
        guard let connection else { return }
        await offlineCache.activate(serverKey: cacheServerKey(connection))
        if showProgress { isRestoringConnection = true }
        defer { if showProgress { isRestoringConnection = false } }
        do {
            let loaded = try await client(for: connection).profile()
            try validateAPIVersion(loaded.apiVersion)
            profile = loaded
            await offlineCache.storeProfile(loaded)
            let cacheStatus = await offlineCache.status()
            cachedAt = cacheStatus.updatedAt
            isOffline = false
            remoteHealth.reset()
            let upgraded = StoredServerConnection(
                copying: connection,
                apiVersion: loaded.apiVersion)
            try store.save(upgraded)
            self.connection = upgraded
            errorMessage = nil
            await flushPendingInboxImports()
        } catch is CancellationError {
            return
        } catch {
            let cachedProfile = await offlineCache.profile()
            profile = cachedProfile
            let cacheStatus = await offlineCache.status()
            cachedAt = cacheStatus.updatedAt
            isOffline = cachedProfile != nil
            if let connectionError = error as? ReadBoardGoConnectionError,
               case .apiVersionMismatch = connectionError {
                try? store.delete()
                self.connection = nil
                remoteHealth.receive(.failed(
                    path: "api/v1/server/profile",
                    kind: .version,
                    message: error.localizedDescription))
            }
            errorMessage = ReadBoardGoConnectionError.userFacingDescription(
                for: error, certificateWasPinned: true)
        }
    }

    /// 断连后保持阅读界面，并以退避间隔在后台恢复服务连接。
    public func monitorConnection() async {
        var retryDelay = 5
        while !Task.isCancelled, connection != nil {
            if isOffline {
                try? await Task.sleep(for: .seconds(retryDelay))
                guard !Task.isCancelled else { return }
                await refreshProfile(showProgress: false)
                retryDelay = isOffline ? min(retryDelay * 2, 30) : 5
            } else {
                retryDelay = 5
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func disconnect() {
        do { try store.delete() } catch { errorMessage = error.localizedDescription }
        connection = nil
        profile = nil
        trustCandidate = nil
        isRestoringConnection = false
        isOffline = false
        cachedAt = nil
        remoteHealth.reset()
    }

    /// 系统分享先落本机暂存，再尝试发送；服务端离线时不会丢失链接。
    public func enqueueInboxImport(_ request: InboxImportRequest) {
        pendingInboxStore.append(request)
        pendingInboxImportCount = pendingInboxStore.load().count
        Task { await flushPendingInboxImports() }
    }

    public func flushPendingInboxImports() async {
        guard !isFlushingInboxImports, connection != nil else { return }
        isFlushingInboxImports = true
        defer {
            isFlushingInboxImports = false
            pendingInboxImportCount = pendingInboxStore.load().count
        }
        for request in pendingInboxStore.load() {
            do {
                _ = try await RemoteInboxGateway(client: try client()).importURL(request)
                pendingInboxStore.remove(requestID: request.requestID)
            } catch {
                if isOffline {
                    errorMessage = "链接已暂存，恢复连接后会自动发送"
                } else {
                    errorMessage = "链接暂未送达：\(error.localizedDescription)"
                }
                break
            }
        }
    }

    /// Go 与 Core 共同页面的远程装配入口。共享页面无需知道 HTTP、证书或登录态细节。
    public func featureEnvironment() throws -> ReadBoardFeatureEnvironment {
        let client = try client()
        return ReadBoardFeatureEnvironment(
            library: CachedRemoteLibraryGateway(client: client, cache: offlineCache),
            contentDetail: CachedRemoteContentDetailGateway(client: client, cache: offlineCache),
            mediaPlayback: RemoteMediaPlaybackGateway(client: client),
            processing: RemoteProcessingGateway(client: client),
            sourceManagement: RemoteSourceManagementGateway(client: client),
            sourceCatalog: CachedRemoteSourceCatalogGateway(client: client, cache: offlineCache),
            sourceOnboarding: RemoteSourceOnboardingGateway(client: client),
            runtimeStatus: RemoteRuntimeStatusGateway(client: client),
            export: RemoteExportGateway(client: client),
            administration: RemoteAdministrationGateway(client: client),
            configuration: RemoteConfigurationGateway(client: client),
            authentication: RemoteAuthenticationGateway(client: client),
            maintenance: RemoteMaintenanceGateway(client: client),
            inbox: RemoteInboxGateway(client: client),
            dependencyManagement: RemoteDependencyManagementGateway(client: client),
            dataRevision: RemoteDataRevisionGateway(client: client),
            permissions: ReadBoardFeaturePermissions(
                capabilities: profile?.capabilities ?? [],
                scopes: profile?.grantedScopes ?? connection?.scopes ?? []))
    }

    private func client() throws -> ReadBoardHTTPClient {
        guard let connection else { throw ReadBoardGoConnectionError.notConnected }
        return client(for: connection)
    }

    private func client(for connection: StoredServerConnection) -> ReadBoardHTTPClient {
        let fingerprint = connection.certificateFingerprint ?? ""
        return ReadBoardHTTPClient(baseURL: connection.baseURL,
            bearerToken: connection.token,
            loader: PinnedHTTPS.client(
                baseURL: connection.baseURL,
                certificateFingerprint: fingerprint),
            eventHandler: { [weak remoteHealth, weak self] event in
                Task { @MainActor in
                    remoteHealth?.receive(event)
                    switch event {
                    case .succeeded:
                        self?.isOffline = false
                    case .failed(_, let kind, _):
                        if kind == .transport { self?.isOffline = true }
                    }
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

    private func cacheServerKey(_ connection: StoredServerConnection) -> String {
        let base = connection.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)|\(connection.certificateFingerprint ?? "untrusted")"
    }
}

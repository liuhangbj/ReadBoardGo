import Foundation
import Observation
import OSLog
import ReadBoardContract
import ReadBoardFeatures
import ReadBoardRemote

@MainActor
@Observable
public final class ReadBoardGoSession {
    private static let logger = Logger(
        subsystem: "com.liuhangbj.readboardgo",
        category: "RemoteConnection")
    public private(set) var connection: StoredServerConnection?
    public private(set) var profile: RemoteServerProfile?
    public private(set) var isWorking = false
    public private(set) var isRestoringConnection = false
    public private(set) var errorMessage: String?
    public private(set) var trustCandidate: ServerTrustCandidate?
    public private(set) var isOffline = false
    public private(set) var cachedAt: Date?
    public private(set) var cacheNotice: String?
    public private(set) var pendingInboxImportCount = 0
    public let discovery = ReadBoardDiscovery()
    public let remoteHealth = ReadBoardRemoteHealthStore()

    private let store: any ConnectionStoring
    private let offlineCache: ReadBoardGoOfflineCache
    private let pendingInboxStore: PendingInboxImportStore
    private let certificateInspector: @Sendable (URL) async throws -> String
    private let profileLoader: (@Sendable (StoredServerConnection) async throws -> RemoteServerProfile)?
    private var isFlushingInboxImports = false
    private var isRefreshingProfile = false
    private var serverInspectionID: UUID?

    public init(
        store: any ConnectionStoring = DefaultConnectionStore(),
        offlineCache: ReadBoardGoOfflineCache = ReadBoardGoOfflineCache(),
        pendingInboxDefaults: UserDefaults = .standard,
        profileLoader: (@Sendable (StoredServerConnection) async throws -> RemoteServerProfile)? = nil,
        certificateInspector: @escaping @Sendable (URL) async throws -> String = {
            try await PinnedHTTPS.inspectCertificate(at: $0)
        }
    ) {
        self.store = store
        self.offlineCache = offlineCache
        self.pendingInboxStore = PendingInboxImportStore(defaults: pendingInboxDefaults)
        self.certificateInspector = certificateInspector
        self.profileLoader = profileLoader
        do {
            let stored = try store.load()
            if let stored, stored.baseURL.scheme == "https",
               stored.certificateFingerprint != nil {
                // 保存的 API 版本只是上次成功连接的快照。服务端升级后设备令牌仍然
                // 有效，应直接探测 profile 并自动刷新版本，不能删除连接、逼用户重输密码。
                // 请求本身会携带当前版本；旧服务端仍会明确返回 426。
                connection = stored
                isRestoringConnection = true
            } else if stored != nil {
                try store.delete()
                errorMessage = "服务端已升级为 HTTPS，请重新登录一次"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshPendingInboxStatus()
    }

    public var isConnected: Bool {
        connection != nil && (profile?.apiVersion == ReadBoardRemoteAPI.version
            || (isOffline && profile != nil))
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
            try await offlineCache.activate(serverKey: cacheServerKey(value))
            try store.save(value)
            connection = value
            self.profile = profile
            await offlineCache.storeProfile(profile)
            cacheNotice = await offlineCache.status().recoveryNotice
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
            try await offlineCache.activate(serverKey: cacheServerKey(value))
            try store.save(value)
            connection = value
            self.profile = profile
            await offlineCache.storeProfile(profile)
            cacheNotice = await offlineCache.status().recoveryNotice
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
        guard let connection, !isRefreshingProfile else { return }
        isRefreshingProfile = true
        defer {
            isRefreshingProfile = false
            if showProgress { isRestoringConnection = false }
        }
        if showProgress { isRestoringConnection = true }
        var wasOffline = isOffline
        var cacheActivated = false
        do {
            try await offlineCache.activate(serverKey: cacheServerKey(connection))
            cacheActivated = true
            guard self.connection == connection, !Task.isCancelled else { return }
            // A saved, identity-bound profile permits finite cached reading while
            // the live probe runs. Do not hold the entire reader behind a timeout.
            if showProgress, profile == nil,
               let cachedProfile = await offlineCache.profile() {
                try validateAPIVersion(cachedProfile.apiVersion)
                let status = await offlineCache.status()
                guard self.connection == connection, !Task.isCancelled else { return }
                profile = cachedProfile
                cachedAt = status.updatedAt
                cacheNotice = status.recoveryNotice
                isOffline = true
                wasOffline = true
                isRestoringConnection = false
                try await offlineCache.scoped(to: cacheServerKey(connection)) {
                    $0.setTransportOffline(true)
                }
            }
            let loaded: RemoteServerProfile
            if let profileLoader {
                loaded = try await profileLoader(connection)
            } else {
                loaded = try await client(for: connection).profile()
            }
            guard self.connection == connection, !Task.isCancelled else { return }
            try validateAPIVersion(loaded.apiVersion)
            profile = loaded
            try await offlineCache.scoped(to: cacheServerKey(connection)) {
                $0.storeProfile(loaded)
                $0.setTransportOffline(false)
            }
            let cacheStatus = await offlineCache.status()
            guard self.connection == connection, !Task.isCancelled else { return }
            cachedAt = cacheStatus.updatedAt
            cacheNotice = cacheStatus.recoveryNotice
            isOffline = false
            remoteHealth.reset()
            let upgraded = StoredServerConnection(
                copying: connection,
                apiVersion: loaded.apiVersion)
            try store.save(upgraded)
            self.connection = upgraded
            errorMessage = nil
            if wasOffline {
                Self.logger.notice("ReadBoard remote profile probe recovered")
            }
            if wasOffline || cacheStatus.pendingReadingMutations > 0 {
                await offlineCache.flushPendingMutations(
                    using: RemoteLibraryGateway(client: client(for: upgraded)),
                    serverKey: cacheServerKey(upgraded))
                guard self.connection == upgraded, !Task.isCancelled else { return }
                NotificationCenter.default.post(name: .readBoardLibrarySnapshotChanged, object: nil)
            }
            await flushPendingInboxImports()
        } catch is CancellationError {
            return
        } catch {
            guard self.connection == connection, !Task.isCancelled else { return }
            let cachedProfile = await offlineCache.profile()
            let cacheStatus = await offlineCache.status()
            guard self.connection == connection, !Task.isCancelled else { return }
            profile = cacheActivated && Self.isTransportDisconnection(error) ? cachedProfile : nil
            cachedAt = cacheStatus.updatedAt
            cacheNotice = cacheStatus.recoveryNotice
            isOffline = profile != nil && Self.isTransportDisconnection(error)
            if cacheActivated {
                try? await offlineCache.scoped(to: cacheServerKey(connection)) {
                    $0.setTransportOffline(Self.isTransportDisconnection(error))
                }
            }
            if isOffline, !wasOffline {
                Self.logger.error("ReadBoard remote profile probe confirmed disconnection")
            }
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

    /// 在线时用低频 profile 探测确认连接；真正断连后保持阅读界面，
    /// 并以退避间隔在后台恢复。普通列表或详情的一次失败不会直接把
    /// 整个会话判定为离线。
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
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, connection != nil else { return }
                await refreshProfile(showProgress: false)
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
        cacheNotice = nil
        remoteHealth.reset()
        refreshPendingInboxStatus()
    }

    /// 系统分享先落本机暂存，再尝试发送；服务端离线时不会丢失链接。
    public func enqueueInboxImport(_ request: InboxImportRequest) {
        pendingInboxStore.append(request, serverKey: connection?.cacheIdentity)
        refreshPendingInboxStatus()
        Task { await flushPendingInboxImports() }
    }

    public func flushPendingInboxImports() async {
        refreshPendingInboxStatus()
        guard !isFlushingInboxImports, !isOffline, let connection else { return }
        let identity = connection.cacheIdentity
        let gateway = RemoteInboxGateway(client: client(for: connection))
        isFlushingInboxImports = true
        defer {
            isFlushingInboxImports = false
            refreshPendingInboxStatus()
        }
        for request in pendingInboxStore.load(serverKey: identity) {
            guard self.connection?.cacheIdentity == identity, !Task.isCancelled else { return }
            do {
                _ = try await gateway.importURL(request)
                pendingInboxStore.remove(requestID: request.requestID, serverKey: identity)
            } catch {
                guard self.connection?.cacheIdentity == identity, !Task.isCancelled else { return }
                if isOffline {
                    errorMessage = "链接已暂存，恢复连接后会自动发送"
                } else {
                    errorMessage = "链接暂未送达：\(error.localizedDescription)"
                }
                break
            }
        }
    }

    private func refreshPendingInboxStatus() {
        pendingInboxImportCount = pendingInboxStore.load(serverKey: connection?.cacheIdentity).count
        if pendingInboxStore.unassignedCount > 0 {
            cacheNotice = "有 \(pendingInboxStore.unassignedCount) 条旧版或未连接时暂存的链接已保留；因无法确认所属服务器，未自动发送，请在确认连接后重新分享。"
        }
    }

    /// Go 与 Core 共同页面的远程装配入口。共享页面无需知道 HTTP、证书或登录态细节。
    public func featureEnvironment() throws -> ReadBoardFeatureEnvironment {
        guard let connection else { throw ReadBoardGoConnectionError.notConnected }
        let serverKey = cacheServerKey(connection)
        let client = try client()
        return ReadBoardFeatureEnvironment(
            library: CachedRemoteLibraryGateway(client: client, cache: offlineCache, serverKey: serverKey),
            contentDetail: CachedRemoteContentDetailGateway(client: client, cache: offlineCache, serverKey: serverKey),
            mediaPlayback: RemoteMediaPlaybackGateway(client: client),
            processing: RemoteProcessingGateway(client: client),
            sourceManagement: RemoteSourceManagementGateway(client: client),
            sourceCatalog: CachedRemoteSourceCatalogGateway(client: client, cache: offlineCache, serverKey: serverKey),
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
                scopes: profile?.grantedScopes ?? connection.scopes))
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
            eventHandler: { [weak self] event in
                Task { @MainActor in
                    self?.receiveRemoteEvent(event)
                }
            })
    }

    /// Request-level health remains observable, but only an authoritative
    /// profile probe may change the whole session's online/offline state.
    func receiveRemoteEvent(_ event: RemoteRequestEvent) {
        remoteHealth.receive(event)
    }

    /// Only failures that mean the server cannot be reached should enter the
    /// offline retry loop. Authorization, API-version, server and decoding
    /// failures have their own observable states and must not masquerade as a
    /// dropped network connection.
    nonisolated static func isTransportDisconnection(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                    .internationalRoamingOff, .dataNotAllowed].contains(error.code)
        }
        if let connectionError = error as? ReadBoardGoConnectionError {
            switch connectionError {
            case .serverNotFound, .serverUnavailable, .connectionTimedOut,
                 .networkUnavailable, .secureConnectionFailed, .connectionFailed:
                return true
            case .invalidServerAddress, .emptyPairingCode, .notConnected,
                 .tlsRequired, .certificateUnavailable, .certificateNotTrusted,
                 .unsafeRedirect, .apiVersionMismatch, .requestCancelled:
                return false
            }
        }
        if let remoteError = error as? RemoteClientError {
            switch remoteError {
            case .invalidResponse:
                return true
            case .invalidURL, .versionMismatch, .server:
                return false
            }
        }
        return false
    }

    private func validateAPIVersion(_ serverVersion: String) throws {
        guard serverVersion == ReadBoardRemoteAPI.version else {
            throw ReadBoardGoConnectionError.apiVersionMismatch(
                client: ReadBoardRemoteAPI.version,
                server: serverVersion)
        }
    }

    private func cacheServerKey(_ connection: StoredServerConnection) -> String {
        connection.cacheIdentity
    }
}

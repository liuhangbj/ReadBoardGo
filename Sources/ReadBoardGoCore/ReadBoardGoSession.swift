import Foundation
import Observation
import ReadBoardContract
import ReadBoardRemote

@MainActor
@Observable
public final class ReadBoardGoSession {
    public private(set) var connection: StoredServerConnection?
    public private(set) var profile: RemoteServerProfile?
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    public private(set) var trustCandidate: ServerTrustCandidate?
    public let discovery = ReadBoardDiscovery()

    private let store: any ConnectionStoring

    public init(store: any ConnectionStoring = KeychainConnectionStore()) {
        self.store = store
        do {
            let stored = try store.load()
            if let stored, stored.baseURL.scheme == "https",
               stored.certificateFingerprint != nil {
                connection = stored
            } else if stored != nil {
                try store.delete()
                errorMessage = "服务端已升级为 HTTPS，请重新登录一次"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var isConnected: Bool { connection != nil }

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
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, session: session).profile()
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
            let value = StoredServerConnection(baseURL: trustCandidate.baseURL,
                credential: credential,
                certificateFingerprint: trustCandidate.certificateFingerprint)
            let profile = try await ReadBoardHTTPClient(baseURL: trustCandidate.baseURL,
                bearerToken: credential.token, session: session).profile()
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
        do {
            profile = try await client(for: connection).profile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func disconnect() {
        do { try store.delete() } catch { errorMessage = error.localizedDescription }
        connection = nil
        profile = nil
        trustCandidate = nil
    }

    public func libraryPage(_ query: ContentQuery = ContentQuery()) async throws -> ContentPage {
        try await RemoteLibraryGateway(client: try client()).page(query)
    }

    public func contentDetail(id: Int64) async throws -> ContentDetail {
        try await RemoteContentDetailGateway(client: try client()).detail(contentID: id)
    }

    public func setRead(id: Int64, value: Bool) async throws -> ContentState {
        try await RemoteLibraryGateway(client: try client()).setRead(contentID: id, isRead: value)
    }

    public func sourceCatalog() async throws -> SourceCatalogSnapshot {
        try await RemoteSourceCatalogGateway(client: try client()).snapshot()
    }

    public func runtimeStatus() async -> RuntimeStatusSnapshot {
        guard let client = try? client() else { return RuntimeStatusSnapshot() }
        return await RemoteRuntimeStatusGateway(client: client).snapshot(refreshCounts: true)
    }

    public func authenticationStatuses() async -> [PlatformAuthenticationStatus] {
        guard let client = try? client() else { return [] }
        return await RemoteAuthenticationGateway(client: client).statuses()
    }

    private func client() throws -> ReadBoardHTTPClient {
        guard let connection else { throw ReadBoardGoConnectionError.notConnected }
        return client(for: connection)
    }

    private func client(for connection: StoredServerConnection) -> ReadBoardHTTPClient {
        let fingerprint = connection.certificateFingerprint ?? ""
        return ReadBoardHTTPClient(baseURL: connection.baseURL,
            bearerToken: connection.token,
            session: PinnedHTTPS.session(certificateFingerprint: fingerprint))
    }
}

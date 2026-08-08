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

    private let store: any ConnectionStoring

    public init(store: any ConnectionStoring = KeychainConnectionStore()) {
        self.store = store
        do {
            connection = try store.load()
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

    public func pair(serverAddress: String, code: String, deviceName: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let baseURL = try ServerAddressNormalizer.normalize(serverAddress)
            let pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pairingCode.isEmpty else { throw ReadBoardGoConnectionError.emptyPairingCode }
            let credential = try await RemotePairingClient.pair(
                baseURL: baseURL, code: pairingCode, deviceName: deviceName)
            let value = StoredServerConnection(baseURL: baseURL, credential: credential)
            let profile = try await ReadBoardHTTPClient(
                baseURL: baseURL, bearerToken: credential.token).profile()
            try store.save(value)
            connection = value
            self.profile = profile
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
        ReadBoardHTTPClient(baseURL: connection.baseURL, bearerToken: connection.token)
    }
}

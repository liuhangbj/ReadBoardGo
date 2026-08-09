import Combine
import Foundation
import ReadBoardContract

/// Contract-backed source catalog state shared by the local Core host and the remote Go host.
@MainActor
public final class SourceCatalogStore: ObservableObject {
    @Published public private(set) var snapshot = SourceCatalogSnapshot()
    @Published public private(set) var isLoading = false

    private let gateway: any SourceCatalogGateway
    private var catalogObserver: AnyCancellable?

    public init(gateway: any SourceCatalogGateway) {
        self.gateway = gateway
        catalogObserver = NotificationCenter.default
            .publisher(for: Notification.Name("sourceCatalogUpdated"))
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    public var sources: [SourceCatalogItem] { snapshot.sources }
    public var folders: [SourceFolderItem] { snapshot.folders }
    public var isSyncing: Bool { snapshot.isSyncing || snapshot.isExternalSyncing }
    public var lastSyncMessage: String { snapshot.lastSyncMessage }

    public func sources(inFolder folderID: Int64) -> [SourceCatalogItem] {
        sources.filter { $0.folderID == folderID }
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let loaded = try? await gateway.snapshot() {
            snapshot = loaded
        }
    }

    public func monitor(intervalNanoseconds: UInt64 = 30_000_000_000) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}

import Foundation
import Combine
import ReadBoardContract

extension Notification.Name {
    static let sourceCatalogUpdated = Notification.Name("sourceCatalogUpdated")
}

@MainActor
final class RuntimeStatusStore: ObservableObject {
    @Published private(set) var snapshot = RuntimeStatusSnapshot()
    private let gateway: any RuntimeStatusGateway

    init(gateway: any RuntimeStatusGateway) {
        self.gateway = gateway
    }

    func refresh(recalculate: Bool = false) async {
        snapshot = await gateway.snapshot(refreshCounts: recalculate)
    }

    func monitor(intervalNanoseconds: UInt64 = 1_000_000_000) async {
        var first = true
        while !Task.isCancelled {
            await refresh(recalculate: first)
            first = false
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    func runOnce() async {
        await gateway.runProcessingScan()
        await refresh()
    }
}

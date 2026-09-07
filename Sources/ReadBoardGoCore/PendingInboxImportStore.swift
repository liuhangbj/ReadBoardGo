import Foundation
import ReadBoardContract

struct PendingInboxImportStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "readboard.go.pending-inbox-imports.v2"
    private let legacyKey = "readboard.go.pending-inbox-imports.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func allQueues() -> [String: [InboxImportRequest]] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: [InboxImportRequest]].self, from: data)
        else { return [:] }
        return values
    }

    func load(serverKey: String?) -> [InboxImportRequest] {
        guard let serverKey else { return [] }
        return allQueues()[serverKey] ?? []
    }

    var unassignedCount: Int {
        let legacy = defaults.data(forKey: legacyKey).flatMap {
            try? JSONDecoder().decode([InboxImportRequest].self, from: $0)
        } ?? []
        return legacy.count + (allQueues()["unassigned"]?.count ?? 0)
    }

    func append(_ request: InboxImportRequest, serverKey: String?) {
        let identity = serverKey ?? "unassigned"
        var queues = allQueues()
        var values = queues[identity] ?? []
        guard !values.contains(where: { $0.requestID == request.requestID }) else { return }
        values.append(request)
        queues[identity] = values
        save(queues)
    }

    func remove(requestID: String, serverKey: String) {
        var queues = allQueues()
        queues[serverKey] = load(serverKey: serverKey).filter { $0.requestID != requestID }
        save(queues)
    }

    private func save(_ values: [String: [InboxImportRequest]]) {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
        }
    }
}

import Foundation
import ReadBoardContract

struct PendingInboxImportStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "readboard.go.pending-inbox-imports.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [InboxImportRequest] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([InboxImportRequest].self, from: data)
        else { return [] }
        return values
    }

    func append(_ request: InboxImportRequest) {
        var values = load()
        guard !values.contains(where: { $0.requestID == request.requestID }) else { return }
        values.append(request)
        save(values)
    }

    func remove(requestID: String) {
        save(load().filter { $0.requestID != requestID })
    }

    private func save(_ values: [InboxImportRequest]) {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
        }
    }
}

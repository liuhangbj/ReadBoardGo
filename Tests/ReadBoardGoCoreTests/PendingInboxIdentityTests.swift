import Foundation
import XCTest
import ReadBoardContract
@testable import ReadBoardGoCore

final class PendingInboxIdentityTests: XCTestCase {
    func testIdentityBoundQueuesAndUnassignedLegacyNeverCrossServers() throws {
        let suite = "readboard-inbox-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingInboxImportStore(defaults: defaults)
        let request = InboxImportRequest(requestID: "same-id", url: "https://example.invalid/a", suggestedKind: .article)
        store.append(request, serverKey: "server-A/credential-1")
        XCTAssertEqual(store.load(serverKey: "server-A/credential-1").count, 1)
        XCTAssertTrue(store.load(serverKey: "server-B/credential-2").isEmpty)
        XCTAssertTrue(store.load(serverKey: nil).isEmpty)
        store.append(request, serverKey: "server-B/credential-2")
        store.remove(requestID: request.requestID, serverKey: "server-B/credential-2")
        XCTAssertEqual(store.load(serverKey: "server-A/credential-1").count, 1)
        let restarted = PendingInboxImportStore(defaults: defaults)
        XCTAssertEqual(restarted.load(serverKey: "server-A/credential-1").count, 1)
        defaults.set(try JSONEncoder().encode([request]), forKey: "readboard.go.pending-inbox-imports.v1")
        restarted.append(request, serverKey: nil)
        XCTAssertEqual(restarted.unassignedCount, 2)
        XCTAssertTrue(restarted.load(serverKey: "new-login").isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "readboard.go.pending-inbox-imports.v1"))
    }
}

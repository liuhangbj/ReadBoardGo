import Foundation
import Security

public protocol ConnectionStoring: Sendable {
    func load() throws -> StoredServerConnection?
    func save(_ connection: StoredServerConnection) throws
    func delete() throws
}

public struct KeychainConnectionStore: ConnectionStoring, Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.hangbits.ReadBoardGo",
                account: String = "active-server") {
        self.service = service
        self.account = account
    }

    public func load() throws -> StoredServerConnection? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status)
        }
        return try JSONDecoder().decode(StoredServerConnection.self, from: data)
    }

    public func save(_ connection: StoredServerConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败（\(status)）"
    }
}

import Foundation
import LocalAuthentication
import Security

public protocol ConnectionStoring: Sendable {
    func load() throws -> StoredServerConnection?
    func save(_ connection: StoredServerConnection) throws
    func delete() throws
}

public struct KeychainConnectionStore: ConnectionStoring, Sendable {
    private let service: String
    private let account: String
    private let allowsAuthenticationUI: Bool

    public init(service: String = "com.hangbits.ReadBoardGo",
                account: String = "active-server",
                allowsAuthenticationUI: Bool = true) {
        self.service = service
        self.account = account
        self.allowsAuthenticationUI = allowsAuthenticationUI
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !allowsAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Keep the legacy flag as a macOS Keychain ACL fallback. Some
            // ad-hoc-signed builds ignore LAContext for old generic-password
            // items and otherwise launch SecurityAgent during migration.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }
}

/// macOS 开发版会被频繁重新签名。把设备令牌放进旧式钥匙串项目会让系统把
/// 每次编译视作新客户端并弹出一个无法用连接密码解开的授权框。该存储只写入
/// 当前用户的 Application Support，目录 0700、文件 0600；iOS 仍使用钥匙串。
public struct FileConnectionStore: ConnectionStoring, Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("ReadBoard Go", isDirectory: true)
            .appendingPathComponent("connection.json")
    }

    public func load() throws -> StoredServerConnection? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            StoredServerConnection.self,
            from: Data(contentsOf: fileURL))
    }

    public func save(_ connection: StoredServerConnection) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(connection).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public struct DefaultConnectionStore: ConnectionStoring, Sendable {
    #if os(macOS)
    private let file = FileConnectionStore()
    #else
    private let keychain = KeychainConnectionStore()
    #endif

    public init() {}

    public func load() throws -> StoredServerConnection? {
        #if os(macOS)
        if let saved = try file.load() { return saved }
        // Never let legacy migration display a password dialog. If the old item
        // can be read silently, migrate it; otherwise the user logs in once.
        if let legacy = try? KeychainConnectionStore(
            allowsAuthenticationUI: false).load() {
            try file.save(legacy)
            return legacy
        }
        return nil
        #else
        return try keychain.load()
        #endif
    }

    public func save(_ connection: StoredServerConnection) throws {
        #if os(macOS)
        try file.save(connection)
        #else
        try keychain.save(connection)
        #endif
    }

    public func delete() throws {
        #if os(macOS)
        try file.delete()
        #else
        try keychain.delete()
        #endif
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败（\(status)）"
    }
}

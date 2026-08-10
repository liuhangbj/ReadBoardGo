import Foundation
import ReadBoardContract

public struct StoredServerConnection: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let deviceID: String
    public let deviceName: String
    public let token: String
    public let scopes: [RemoteAccessScope]
    public let certificateFingerprint: String?
    public let apiVersion: String?

    public init(baseURL: URL, credential: RemotePairingCredential,
                certificateFingerprint: String) {
        self.baseURL = baseURL
        deviceID = credential.deviceID
        deviceName = credential.deviceName
        token = credential.token
        scopes = credential.scopes
        self.certificateFingerprint = certificateFingerprint
        apiVersion = credential.apiVersion
    }

    public init(copying value: StoredServerConnection, apiVersion: String) {
        baseURL = value.baseURL
        deviceID = value.deviceID
        deviceName = value.deviceName
        token = value.token
        scopes = value.scopes
        certificateFingerprint = value.certificateFingerprint
        self.apiVersion = apiVersion
    }
}

public struct ServerTrustCandidate: Identifiable, Equatable, Sendable {
    public var id: String { certificateFingerprint }
    public let name: String
    public let baseURL: URL
    public let certificateFingerprint: String

    public init(name: String, baseURL: URL, certificateFingerprint: String) {
        self.name = name; self.baseURL = baseURL
        self.certificateFingerprint = certificateFingerprint
    }
}

public enum ReadBoardGoConnectionError: LocalizedError {
    case invalidServerAddress
    case emptyPairingCode
    case notConnected
    case tlsRequired
    case certificateUnavailable
    case certificateNotTrusted
    case apiVersionMismatch(client: String, server: String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "服务器地址无效"
        case .emptyPairingCode: "请输入配对码"
        case .notConnected: "尚未连接 ReadBoard 服务"
        case .tlsRequired: "ReadBoard Go 只允许通过 HTTPS 连接"
        case .certificateUnavailable: "无法读取服务器 TLS 证书"
        case .certificateNotTrusted: "服务器证书未受信任或已发生变化"
        case .apiVersionMismatch(let client, let server):
            "客户端接口版本为 \(client)，服务器接口版本为 \(server)，请升级 ReadBoard Go 或服务端"
        }
    }
}

public enum ServerAddressNormalizer {
    public static func normalize(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ReadBoardGoConnectionError.invalidServerAddress }
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host != nil else {
            throw ReadBoardGoConnectionError.invalidServerAddress
        }
        components.scheme = scheme
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let result = components.url else {
            throw ReadBoardGoConnectionError.invalidServerAddress
        }
        return result
    }
}

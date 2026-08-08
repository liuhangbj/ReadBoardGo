import Foundation
import ReadBoardContract

public struct StoredServerConnection: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let deviceID: String
    public let deviceName: String
    public let token: String
    public let scopes: [RemoteAccessScope]

    public init(baseURL: URL, credential: RemotePairingCredential) {
        self.baseURL = baseURL
        deviceID = credential.deviceID
        deviceName = credential.deviceName
        token = credential.token
        scopes = credential.scopes
    }
}

public enum ReadBoardGoConnectionError: LocalizedError {
    case invalidServerAddress
    case emptyPairingCode
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "服务器地址无效"
        case .emptyPairingCode: "请输入配对码"
        case .notConnected: "尚未连接 ReadBoard 服务"
        }
    }
}

public enum ServerAddressNormalizer {
    public static func normalize(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ReadBoardGoConnectionError.invalidServerAddress }
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
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

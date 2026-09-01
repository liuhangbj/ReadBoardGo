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
    case serverNotFound
    case serverUnavailable
    case connectionTimedOut
    case networkUnavailable
    case secureConnectionFailed
    case requestCancelled
    case unsafeRedirect
    case connectionFailed
    case apiVersionMismatch(client: String, server: String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "服务器地址无效"
        case .emptyPairingCode: "请输入配对码"
        case .notConnected: "尚未连接 ReadBoard 服务"
        case .tlsRequired: "ReadBoard Go 只允许通过 HTTPS 连接"
        case .certificateUnavailable: "无法读取服务器 TLS 证书"
        case .certificateNotTrusted: "服务器证书未受信任或已发生变化"
        case .serverNotFound: "找不到服务器，请检查动态域名或服务器地址"
        case .serverUnavailable: "无法连接服务器，请确认远程访问已开启且端口可达"
        case .connectionTimedOut: "连接服务器超时，请检查网络和端口转发"
        case .networkUnavailable: "网络连接不可用，请检查网络后重试"
        case .secureConnectionFailed: "无法建立 TLS 安全连接，请检查代理、服务器地址或证书"
        case .requestCancelled: "连接请求被系统取消，请检查代理或 VPN 后重试"
        case .unsafeRedirect: "服务器返回了不安全的跨域跳转，连接已停止"
        case .connectionFailed: "连接服务器失败，请检查地址和网络后重试"
        case .apiVersionMismatch(let client, let server):
            "客户端接口版本为 \(client)，服务器接口版本为 \(server)，请升级 ReadBoard Go 或服务端"
        }
    }

    static func networkFailure(from error: any Error) -> ReadBoardGoConnectionError {
        if let connectionError = error as? ReadBoardGoConnectionError {
            return connectionError
        }
        guard let urlError = error as? URLError else { return .connectionFailed }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .serverNotFound
        case .cannotConnectToHost:
            return .serverUnavailable
        case .timedOut:
            return .connectionTimedOut
        case .notConnectedToInternet, .networkConnectionLost,
             .internationalRoamingOff, .dataNotAllowed:
            return .networkUnavailable
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnectionFailed
        default:
            return .connectionFailed
        }
    }

    static func userFacingDescription(
        for error: any Error,
        certificateWasPinned: Bool = false
    ) -> String {
        if let connectionError = error as? ReadBoardGoConnectionError {
            return connectionError.localizedDescription
        }
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        if certificateWasPinned {
            switch urlError.code {
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return ReadBoardGoConnectionError.certificateNotTrusted.localizedDescription
            default:
                break
            }
        }
        if urlError.code == .cancelled {
            return ReadBoardGoConnectionError.requestCancelled.localizedDescription
        }
        return networkFailure(from: urlError).localizedDescription
    }
}

public enum ServerAddressNormalizer {
    public static func normalize(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ReadBoardGoConnectionError.invalidServerAddress }
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw ReadBoardGoConnectionError.invalidServerAddress
        }
        guard scheme == "https" else { throw ReadBoardGoConnectionError.tlsRequired }
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

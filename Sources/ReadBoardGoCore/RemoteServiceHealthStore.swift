import Foundation
import Observation
import ReadBoardRemote

public enum ReadBoardRemoteHealthPhase: Sendable, Equatable {
    case healthy
    case degraded
    case disconnected
    case incompatible
}

@MainActor
@Observable
public final class ReadBoardRemoteHealthStore {
    public private(set) var phase: ReadBoardRemoteHealthPhase = .healthy
    public private(set) var message: String?
    public private(set) var failingPaths: Set<String> = []
    private var failures: [String: (kind: RemoteRequestFailureKind, detail: String)] = [:]

    public init() {}

    public func receive(_ event: RemoteRequestEvent) {
        switch event {
        case .succeeded(let path):
            failures.removeValue(forKey: path)
            rebuildStatus()
        case .failed(let path, let kind, let detail):
            failures[path] = (kind, detail)
            rebuildStatus()
        }
    }

    public func reset() {
        phase = .healthy
        message = nil
        failingPaths.removeAll()
        failures.removeAll()
    }

    private func rebuildStatus() {
        failingPaths = Set(failures.keys)
        guard !failures.isEmpty else {
            phase = .healthy
            message = nil
            return
        }
        let selected = failures.values.max { priority($0.kind) < priority($1.kind) }!
        switch selected.kind {
        case .version:
            phase = .incompatible
            message = "客户端与服务端接口版本不兼容"
        case .transport:
            if failures["api/v1/server/profile"]?.kind == .transport {
                phase = .disconnected
                message = "无法连接 ReadBoard 服务：\(selected.detail)"
            } else {
                phase = .degraded
                message = "ReadBoard 部分服务请求超时，正在等待自动重试"
            }
        case .authorization:
            phase = .degraded
            message = "当前设备没有执行此操作的权限"
        case .server, .decoding, .unknown:
            phase = .degraded
            message = "ReadBoard 服务请求失败：\(selected.detail)"
        }
    }

    private func priority(_ kind: RemoteRequestFailureKind) -> Int {
        switch kind {
        case .version: 4
        case .transport: 3
        case .authorization: 2
        case .server, .decoding, .unknown: 1
        }
    }
}

import Foundation
import Network
import Observation

public struct DiscoveredReadBoardServer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURLs: [URL]
    public let certificateFingerprint: String
    public let apiVersion: String

    public init(id: String, name: String, baseURLs: [URL],
                certificateFingerprint: String, apiVersion: String) {
        self.id = id; self.name = name; self.baseURLs = baseURLs
        self.certificateFingerprint = certificateFingerprint
        self.apiVersion = apiVersion
    }
}

@MainActor
@Observable
public final class ReadBoardDiscovery: @unchecked Sendable {
    public private(set) var servers: [DiscoveredReadBoardServer] = []
    public private(set) var statusMessage = "正在查找局域网中的 ReadBoard…"

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "readboard.go.discovery")

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(
            type: "_readboard._tcp", domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.statusMessage = "正在查找局域网中的 ReadBoard…"
                case .failed(let error): self?.statusMessage = error.localizedDescription
                case .waiting(let error): self?.statusMessage = error.localizedDescription
                case .cancelled: self?.statusMessage = "局域网发现已停止"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let values = Self.parse(results: results)
            Task { @MainActor [weak self] in
                self?.servers = values
                if values.isEmpty { self?.statusMessage = "未发现服务器，可手动输入地址" }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        servers = []
    }

    private nonisolated static func parse(
        results: Set<NWBrowser.Result>
    ) -> [DiscoveredReadBoardServer] {
        var values: [String: DiscoveredReadBoardServer] = [:]
        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata else { continue }
            let dictionary = txtRecord.dictionary
            guard let fingerprint = dictionary["fingerprint"],
                  !fingerprint.isEmpty else { continue }
            let urls = (dictionary["urls"] ?? "").split(separator: ",").compactMap {
                URL(string: String($0))
            }.filter { $0.scheme?.lowercased() == "https" }
            guard !urls.isEmpty else { continue }
            let name = dictionary["name"] ?? serviceName(from: result.endpoint) ?? "ReadBoard"
            values[fingerprint] = DiscoveredReadBoardServer(id: fingerprint,
                name: name, baseURLs: urls, certificateFingerprint: fingerprint,
                apiVersion: dictionary["api"] ?? "")
        }
        return values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        return name
    }
}

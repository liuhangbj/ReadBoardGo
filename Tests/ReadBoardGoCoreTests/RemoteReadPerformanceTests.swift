import Foundation
import ReadBoardContract
import ReadBoardRemote
import ReadBoardUI
import XCTest
@testable import ReadBoardGoCore

/// Explicitly opted-in, read-only benchmark against an already paired server.
/// Never prints credentials, response bodies or article titles; does not mark read.
final class RemoteReadPerformanceTests: XCTestCase {
    /// Bounded authenticated background observation. Uses normal reading APIs
    /// only, never read-state writes, platform requests, or processing commands.
    func testLiveBackgroundReadingSoakWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_RUN_LIVE_READ_SOAK"] == "1",
              let path = ProcessInfo.processInfo.environment["READBOARD_PERF_CONNECTION_FILE"] else {
            throw XCTSkip("Live reading soak requires its own opt-in and connection file")
        }
        let saved = try XCTUnwrap(FileConnectionStore(fileURL: URL(fileURLWithPath: path)).load())
        let pin = try XCTUnwrap(saved.certificateFingerprint)
        let seconds = min(3_600, max(30, Int(ProcessInfo.processInfo.environment["READBOARD_SOAK_SECONDS"] ?? "1800") ?? 1800))
        var endpoints = [("saved", saved.baseURL)]
        if let raw = ProcessInfo.processInfo.environment["READBOARD_SOAK_PUBLIC_URL"],
           let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil {
            endpoints.append(("public", url))
        }
        var gateways: [(String, RemoteLibraryGateway, RemoteContentDetailGateway)] = []
        for (name, url) in endpoints {
            let client = ReadBoardHTTPClient(baseURL: url, bearerToken: saved.token,
                loader: PinnedHTTPS.client(baseURL: url, certificateFingerprint: pin))
            _ = try await client.profile()
            gateways.append((name, RemoteLibraryGateway(client: client), RemoteContentDetailGateway(client: client)))
        }
        let clock = ContinuousClock()
        let started = clock.now
        var cycle = 0
        var successes = 0
        var failures = 0
        func log(_ line: String) {
            // Explicit writes make live progress observable even when stdout is
            // redirected; no token, URL, title or body is included.
            try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
        }
        log("SOAK started=\(Date().timeIntervalSince1970) duration_seconds=\(seconds) endpoints=\(gateways.count)")
        while started.duration(to: clock.now) < .seconds(seconds) {
            for (name, library, content) in gateways {
                let start = Date()
                var phase = "page"
                do {
                    log("SOAK cycle=\(cycle) endpoint=\(name) phase=page event=start")
                    let pageStart = Date()
                    let page = try await library.page(ContentQuery(pageSize: 50))
                    log("SOAK cycle=\(cycle) endpoint=\(name) phase=page milliseconds=\(Int(Date().timeIntervalSince(pageStart) * 1000))")
                    if let item = page.items.first(where: { $0.fetchStatus == 2 || $0.hasTranscript }) {
                        phase = "detail"
                        log("SOAK cycle=\(cycle) endpoint=\(name) phase=detail event=start")
                        let detailStart = Date()
                        let detail = try await content.detail(contentID: item.id)
                        XCTAssertEqual(detail.id, item.id)
                        log("SOAK cycle=\(cycle) endpoint=\(name) phase=detail milliseconds=\(Int(Date().timeIntervalSince(detailStart) * 1000))")
                    }
                    if cycle % 4 == 0 {
                        phase = "snapshot"
                        log("SOAK cycle=\(cycle) endpoint=\(name) phase=snapshot event=start")
                        let snapshotStart = Date()
                        _ = try await library.snapshot()
                        log("SOAK cycle=\(cycle) endpoint=\(name) phase=snapshot milliseconds=\(Int(Date().timeIntervalSince(snapshotStart) * 1000))")
                    }
                    successes += 1
                    log("SOAK cycle=\(cycle) endpoint=\(name) result=ok milliseconds=\(Int(Date().timeIntervalSince(start) * 1000))")
                } catch {
                    failures += 1
                    let error = error as NSError
                    log("SOAK cycle=\(cycle) endpoint=\(name) result=failed domain=\(error.domain) code=\(error.code) milliseconds=\(Int(Date().timeIntervalSince(start) * 1000)) phase=\(phase)")
                }
            }
            cycle += 1
            try await Task.sleep(for: .seconds(15))
        }
        log("SOAK ended=\(Date().timeIntervalSince1970) successes=\(successes) failures=\(failures) cycles=\(cycle)")
        XCTAssertGreaterThan(successes, 0)
        XCTAssertEqual(failures, 0, "Inspect the recorded endpoint/cycle failures; do not report an interrupted soak as passed")
    }

    /// Synthetic cache only: quantify full-envelope write cost without touching
    /// the user's cache, pending reading mutations, or server.
    func testSyntheticCacheAndMarkdownCostsWhenExplicitlyEnabled() async throws {
        guard let root = ProcessInfo.processInfo.environment["READBOARD_PERF_FIXTURE_DIR"] else {
            throw XCTSkip("Synthetic performance fixtures require an explicit temporary directory")
        }
        let directory = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paragraph = "A typical article paragraph with **bold text**, a [reference](https://example.com), and enough plain text to represent a readable article.\n\n"
        let markdown = String(repeating: paragraph, count: 150)
        func detail(_ id: Int64) -> ContentDetail {
            ContentDetail(id: id, contentMarkdown: markdown, translatedMarkdown: markdown,
                transcriptMarkdown: nil, translatedTitle: nil, audioURL: nil, videoID: nil,
                score: 80, summary: "Synthetic performance sample")
        }
        let encoder = JSONEncoder()
        for count in [5, 100, 500] {
            var records: [String: Any] = [:]
            for id in 1...count {
                let value = try JSONSerialization.jsonObject(with: encoder.encode(detail(Int64(id))))
                records[String(id)] = ["value": value, "updatedAt": 1.0]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "details": records, "pages": [:], "pendingMutations": [], "updatedAt": 1.0
            ] as [String: Any])
            let rawWriteStart = Date()
            let rawFile = directory.appendingPathComponent("raw-write-\(count).json")
            try data.write(to: rawFile, options: .atomic)
            print("PERF cache_details=\(count) operation=atomic-write-preencoded total_ms=\(Int(Date().timeIntervalSince(rawWriteStart) * 1000))")
            let file = directory.appendingPathComponent("cache-\(count).json")
            try data.write(to: file, options: .atomic)
            let start = Date()
            let cache = ReadBoardGoOfflineCache(fileURL: file)
            print("PERF cache_details=\(count) bytes=\(data.count) operation=init total_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
            let restored = await cache.detail(contentID: 1)
            XCTAssertEqual(restored, detail(1))
            for iteration in 0..<3 {
                let detailStart = Date()
                await cache.storeDetail(detail(1))
                print("PERF cache_details=\(count) operation=store-detail iteration=\(iteration) total_ms=\(Int(Date().timeIntervalSince(detailStart) * 1000))")
                let pageStart = Date()
                await cache.storePage(ContentPage(items: [], nextCursor: nil), query: ContentQuery())
                print("PERF cache_details=\(count) operation=store-empty-page iteration=\(iteration) total_ms=\(Int(Date().timeIntervalSince(pageStart) * 1000))")
            }
        }
        for multiplier in [1, 5] {
            let text = String(repeating: markdown, count: multiplier)
            for iteration in 0..<3 {
                let start = Date()
                let html = ReadBoardHTMLDocumentRenderer.renderMarkdown(text, baseURL: nil)
                XCTAssertFalse(html.isEmpty)
                print("PERF markdown_bytes=\(text.utf8.count) operation=render-markdown iteration=\(iteration) total_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
            }
        }
    }

    func testLiveReadPerformanceWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["READBOARD_RUN_LIVE_READ_PERF"] == "1",
              let path = ProcessInfo.processInfo.environment["READBOARD_PERF_CONNECTION_FILE"] else {
            throw XCTSkip("Live read performance requires an explicit connection file and opt-in")
        }
        let saved = try XCTUnwrap(FileConnectionStore(fileURL: URL(fileURLWithPath: path)).load())
        let pin = try XCTUnwrap(saved.certificateFingerprint)
        let endpoints = [("saved", saved.baseURL), ("loopback", URL(string: "https://127.0.0.1:7331/")!)]
        for (endpoint, url) in endpoints {
            let loader = ReadPerformanceLoader(base: PinnedHTTPS.client(baseURL: url, certificateFingerprint: pin))
            let client = ReadBoardHTTPClient(baseURL: url, bearerToken: saved.token, loader: loader)
            _ = try await client.profile()
            let library = RemoteLibraryGateway(client: client)
            let content = RemoteContentDetailGateway(client: client)
            let queries: [(String, ContentQuery)] = [
                ("all-50", ContentQuery(pageSize: 50)),
                ("all-300", ContentQuery(pageSize: 300)),
                ("articles-300", ContentQuery(filter: ContentFilter(category: .article, sourceFamily: .nonSocial), pageSize: 300)),
                ("videos-300", ContentQuery(filter: ContentFilter(category: .video, sourceFamily: .nonSocial), pageSize: 300)),
                ("podcasts-300", ContentQuery(filter: ContentFilter(category: .podcast), pageSize: 300)),
                ("score-range-300", ContentQuery(filter: ContentFilter(minimumScore: 0, maximumScore: 100, includeUnscored: true), pageSize: 300)),
                ("inbox", ContentQuery(filter: ContentFilter(inboxOnly: true), pageSize: 300))
            ]
            var samples: [ContentSummary] = []
            for (name, query) in queries {
                for iteration in 0..<3 {
                    let start = Date()
                    let page = try await library.page(query)
                    print("PERF endpoint=\(endpoint) operation=\(name) iteration=\(iteration) items=\(page.items.count) total_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
                    if iteration == 0 {
                        samples.append(contentsOf: page.items.filter { $0.fetchStatus == 2 || $0.hasTranscript }.prefix(2))
                    }
                }
            }
            var seen = Set<Int64>()
            for sample in samples where seen.insert(sample.id).inserted {
                for iteration in 0..<2 {
                    let start = Date()
                    let detail = try await content.detail(contentID: sample.id)
                    XCTAssertEqual(detail.id, sample.id)
                    print("PERF endpoint=\(endpoint) operation=detail id=\(sample.id) iteration=\(iteration) total_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
                }
            }
            for iteration in 0..<3 {
                let start = Date()
                let snapshot = try await library.snapshot()
                print("PERF endpoint=\(endpoint) operation=snapshot iteration=\(iteration) total=\(snapshot.counts.total) total_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
            }
        }
    }
}

private struct ReadPerformanceLoader: RemoteRequestLoading {
    let base: any RemoteRequestLoading
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let start = Date()
        let result = try await base.data(for: request)
        print("PERF transport path=\(request.url?.path ?? "unknown") bytes=\(result.0.count) milliseconds=\(Int(Date().timeIntervalSince(start) * 1000))")
        return result
    }
}

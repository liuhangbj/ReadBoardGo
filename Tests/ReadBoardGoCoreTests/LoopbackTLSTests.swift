#if os(macOS)
import Foundation
import XCTest
@testable import ReadBoardGoCore

final class LoopbackTLSTests: XCTestCase {
    func testPinnedTransportSurvivesServerRestartAndNeverReplaysWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = directory.appendingPathComponent("certificate.pem")
        let key = directory.appendingPathComponent("key.pem")
        let requests = directory.appendingPathComponent("requests.log")
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                              "-subj", "/CN=ReadBoard isolated test", "-out", certificate.path,
                              "-keyout", key.path]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        generate.waitUntilExit()
        XCTAssertEqual(generate.terminationStatus, 0)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tls_fixture.py")
        func start(port: Int) throws -> (Process, Int) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [fixture.path, "--certificate", certificate.path, "--key", key.path,
                                 "--requests", requests.path, "--port", String(port)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            var line = Data()
            while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }
                line.append(byte)
                if line.count > 10 { break }
            }
            guard let actualPort = Int(String(decoding: line, as: UTF8.self)) else {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                throw NSError(domain: "TLSFixture", code: 1)
            }
            return (process, actualPort)
        }
        var (server, port) = try start(port: 0)
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let base = URL(string: "https://127.0.0.1:\(port)")!
        let fingerprint = try await PinnedHTTPS.inspectCertificate(at: base)
        let loader = PinnedHTTPS.client(baseURL: base, certificateFingerprint: fingerprint)
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 3
        let first = try await loader.data(for: request)
        XCTAssertEqual(first.0, Data("{\"ok\":true}".utf8))
        server.terminate()
        server.waitUntilExit()
        do {
            _ = try await loader.data(for: request)
            XCTFail("Stopped server must fail, not return fake success")
        } catch { }
        (server, _) = try start(port: port)
        let recovered = try await loader.data(for: request)
        XCTAssertEqual(recovered.0, first.0)

        let beforeMismatch = try String(contentsOf: requests, encoding: .utf8)
        let wrongPin = PinnedHTTPS.client(baseURL: base,
            certificateFingerprint: String(repeating: "0", count: 64))
        request.setValue("Bearer isolated-test-token", forHTTPHeaderField: "Authorization")
        do {
            _ = try await wrongPin.data(for: request)
            XCTFail("Mismatched certificate must not receive credentials")
        } catch { }
        XCTAssertEqual(try String(contentsOf: requests, encoding: .utf8), beforeMismatch)

        request.url = base.appendingPathComponent("drop")
        request.httpMethod = "POST"
        do {
            _ = try await loader.data(for: request)
            XCTFail("Dropped write must fail")
        } catch { }
        let recorded = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertEqual(recorded.components(separatedBy: "POST /drop").count - 1, 1)
    }
}
#endif

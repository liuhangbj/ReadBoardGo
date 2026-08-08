import XCTest
@testable import ReadBoardGoCore
import ReadBoardContract

final class ReadBoardGoCoreTests: XCTestCase {
    func testServerAddressNormalizationAddsHTTPAndDropsPaths() throws {
        XCTAssertEqual(try ServerAddressNormalizer.normalize("10.0.0.5:7331/path?x=1").absoluteString,
                       "http://10.0.0.5:7331/")
        XCTAssertEqual(try ServerAddressNormalizer.normalize("https://reader.example.com").absoluteString,
                       "https://reader.example.com/")
    }

    func testStoredConnectionRetainsGrantedScopes() throws {
        let credential = RemotePairingCredential(deviceID: "device", deviceName: "iPhone",
            token: "secret", apiVersion: "1", scopes: RemoteAccessScope.reader)
        let value = StoredServerConnection(baseURL: URL(string: "http://10.0.0.5:7331/")!,
                                           credential: credential)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(StoredServerConnection.self, from: data), value)
    }
}

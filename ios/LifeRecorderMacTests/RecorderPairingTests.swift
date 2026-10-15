import CryptoKit
import XCTest
@testable import LifeRecorderMac

final class RecorderPairingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func writeAgent(_ arguments: [String]) throws -> URL {
        let url = folder.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": arguments], format: .xml, options: 0)
            .write(to: url)
        return url
    }

    func testReadsTheRecordersTokenCertificateAndReceiver() throws {
        let der = Data((0..<600).map { UInt8($0 % 251) })
        let pem = "-----BEGIN CERTIFICATE-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END CERTIFICATE-----\n"
        try pem.write(to: folder.appendingPathComponent("receiver.crt"), atomically: true, encoding: .utf8)
        try "secret-token\n".write(to: folder.appendingPathComponent("receiver.token"), atomically: true, encoding: .utf8)
        let agent = try writeAgent(["/path/LifeRecorderCapture", "--receiver", "https://desk.example.ts.net:8443"])

        let settings = try XCTUnwrap(RecorderPairing.load(directory: folder, agent: agent))
        XCTAssertEqual(settings.baseURL.absoluteString, "https://desk.example.ts.net:8443")
        XCTAssertEqual(settings.token, "secret-token")
        XCTAssertEqual(settings.certificateSHA256, SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }

    func testAMacWithoutTheRecorderIsNotPaired() throws {
        let agent = try writeAgent(["/path/LifeRecorderCapture", "--receiver", "https://desk.example.ts.net:8443"])
        XCTAssertNil(RecorderPairing.load(directory: folder, agent: agent), "No token or certificate")
        XCTAssertNil(RecorderPairing.pin(ofCertificate: "not a certificate"))
    }

    func testOnlyAnHTTPSReceiverIsAccepted() throws {
        XCTAssertNil(RecorderPairing.receiver(inAgent: try writeAgent(["/path/LifeRecorderCapture"])))
        XCTAssertNil(RecorderPairing.receiver(inAgent: try writeAgent(["/path/LifeRecorderCapture", "--receiver"])))
        XCTAssertNil(RecorderPairing.receiver(inAgent: try writeAgent(["x", "--receiver", "http://desk.example:8443"])))
        XCTAssertNil(RecorderPairing.receiver(inAgent: folder.appendingPathComponent("missing.plist")))
    }
}

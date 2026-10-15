import CryptoKit
import Foundation

/// The pairing the Mac meeting recorder (desktop/capture_mac) already holds: its token and
/// certificate, and the receiver its launch agent uploads to. A Mac that runs the recorder
/// reads its days through that, with nothing to enter.
enum RecorderPairing {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let directory = home.appendingPathComponent("Library/Application Support/LifeRecorder", isDirectory: true)
    static let agent = home.appendingPathComponent("Library/LaunchAgents/com.unayung.life-recorder.capture.plist")

    static func load(directory: URL = directory, agent: URL = agent) -> ReceiverSettings? {
        guard let token = (try? String(contentsOf: directory.appendingPathComponent("receiver.token"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let certificate = try? String(contentsOf: directory.appendingPathComponent("receiver.crt"), encoding: .utf8),
              let pin = pin(ofCertificate: certificate),
              let receiver = receiver(inAgent: agent) else { return nil }
        return ReceiverSettings(baseURL: receiver, token: token, certificateSHA256: pin)
    }

    /// SHA-256 of the certificate's DER bytes: the fingerprint the phone is given when it pairs.
    static func pin(ofCertificate pem: String) -> String? {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard !body.isEmpty, let der = Data(base64Encoded: body) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The address after `--receiver` in the recorder's launch agent.
    static func receiver(inAgent plist: URL) -> URL? {
        guard let data = try? Data(contentsOf: plist),
              let agent = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = agent["ProgramArguments"] as? [String],
              let flag = arguments.firstIndex(of: "--receiver"), arguments.indices.contains(flag + 1),
              let url = URL(string: arguments[flag + 1]), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

extension ReceiverSettings {
    /// Drop the pairing entered in Settings, going back to the recorder's.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: "receiverURL")
        UserDefaults.standard.removeObject(forKey: "certificateSHA256")
    }
}

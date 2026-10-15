import CryptoKit
import Foundation
import Security

/// The pinned connection to the Mac, shared by uploads and by reading days back.
final class PinnedTransport: NSObject, URLSessionDelegate {
    static let shared = PinnedTransport()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        PinnedTransport.verify(challenge, completionHandler)
    }

    static func verify(_ challenge: URLAuthenticationChallenge,
                       _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let settings = ReceiverSettings.load(),
              challenge.protectionSpace.host.lowercased() == settings.baseURL.host?.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if settings.certificateSHA256.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            .map { String(format: "%02x", $0) }.joined()
        if hash == settings.certificateSHA256 {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

import Foundation
import Security
import ScannerStreamingCore

/// Typed pairing observes a certificate and immediately cancels TLS. It never sends the token,
/// device credential, HTTP authorization or scan data. Human SAS confirmation happens afterwards.
final class CertificateProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let address: PairingAddress
    private let lock = NSLock()
    private var observed: String?
    init(address: PairingAddress) { self.address = address }

    func fingerprint() async throws -> String {
        guard let url = URL(string: "https://\(address.isIPv6 ? "[\(address.host)]" : address.host):\(address.port)/") else {
            throw StreamError.invalid("Probe address")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: url) } catch { /* cancellation at TLS is expected */ }
        guard let pin = value() else { throw StreamConnection.Failure.disconnected }
        return pin
    }

    private func value() -> String? { lock.lock(); defer { lock.unlock() }; return observed }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           PinnedSocket.matchesHost(challenge.protectionSpace.host, address: address),
           challenge.protectionSpace.port == Int(address.port), let trust = challenge.protectionSpace.serverTrust,
           let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first {
            let pin = PairingIdentity.fingerprint(leafCertificateDER: SecCertificateCopyData(leaf) as Data)
            lock.lock(); observed = pin; lock.unlock()
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

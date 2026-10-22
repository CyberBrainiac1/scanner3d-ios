import Foundation
import Security
import Network
import ScannerStreamingCore

/// Transport only. The caller must obtain the human's SAS confirmation BEFORE constructing this
/// object with a pairing token. The TLS leaf pin is checked on every connection; redirects fail closed.
final class PinnedSocket: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let address: PairingAddress
    private let fingerprint: String
    private var session: URLSession!
    private(set) var task: URLSessionWebSocketTask!

    init(address: PairingAddress, fingerprint: String, channel: String) throws {
        guard ["preview", "originals"].contains(channel),
              let url = address.url(path: "/s3d/v1/\(channel)") else { throw StreamError.invalid("Socket address") }
        self.address = address; self.fingerprint = fingerprint
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = ControlOutbox.helloMaximumBytes
        task.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.matchesHost(challenge.protectionSpace.host, address: address),
              challenge.protectionSpace.port == Int(address.port),
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first,
              (try? PairingIdentity.matchesPin(leafCertificateDER: SecCertificateCopyData(leaf) as Data,
                                               expectedFingerprint: fingerprint)) == true else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func send(_ frame: SocketWriter.Frame) async throws {
        switch frame {
        case .text(let data):
            guard let text = String(data: data, encoding: .utf8) else { throw StreamError.invalid("UTF8 control") }
            try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data: throw StreamError.invalid("PC must send text control messages")
        @unknown default: throw StreamError.invalid("Unknown WebSocket frame")
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }

    static func matchesHost(_ host: String, address: PairingAddress) -> Bool {
        let observed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.isIPv6 {
            guard let a = IPv6Address(observed), let b = IPv6Address(address.host) else { return false }
            return a.rawValue == b.rawValue
        }
        guard let a = IPv4Address(observed), let b = IPv4Address(address.host) else { return false }
        return a.rawValue == b.rawValue
    }
}

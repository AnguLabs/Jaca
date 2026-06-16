import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

/// Failures that must not be papered over by minting a replacement CA.
enum CAError: Error { case keyPresentButUnreadable }

/// Generates and persists a local root CA, and mints per-host leaf certificates
/// signed by it so the MITM proxy can terminate TLS for any host. The user
/// installs/ trusts the root CA on the device; leaves are cached per host.
final class CertificateAuthority: @unchecked Sendable {
    private let caCertificate: Certificate
    private let caKey: P256.Signing.PrivateKey
    private let caNIOCertificate: NIOSSLCertificate

    private let lock = NSLock()
    private var contextCache: [String: NIOSSLContext] = [:]

    let rootCertificatePEM: String
    let storageDirectory: URL

    /// Loads the CA from `directory` (default: Application Support/Jaca/ca), generating and
    /// persisting a new one if absent. The private key is a 0600 file next to the cert. A key
    /// still in the Keychain from older builds is migrated to the file on first read (one last
    /// prompt), then used from the file — which avoids the per-launch Keychain ACL prompt that
    /// dogs locally-signed dev builds (the approach mitmproxy/Charles use for their CA key).
    init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jaca/ca", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageDirectory = dir

        let certURL = dir.appendingPathComponent("rootCA.pem")
        let keyURL = dir.appendingPathComponent("rootCA.key.pem")
        let keyAccount = "ca-private-key"
        let migrateFromKeychain = (directory == nil)   // only the real app ever used the Keychain

        func loadKeyPEM() -> String? {
            if let fromFile = try? String(contentsOf: keyURL, encoding: .utf8) { return fromFile }
            // One-time migration: read an existing key still in the Keychain (a final prompt),
            // write it to the file, and use the file from then on.
            if migrateFromKeychain, let stored = KeychainStore.read(account: keyAccount) {
                try? Self.writeKeyFile(stored, to: keyURL)
                return stored
            }
            return nil
        }

        let certPEM = try? String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = loadKeyPEM()
        if let certPEM, let keyPEM,
           let cert = try? Certificate(pemEncoded: certPEM),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) {
            caCertificate = cert
            caKey = key
        } else {
            // Don't silently replace an existing CA we just couldn't read (e.g. the migration
            // prompt was dismissed) — that would invalidate every installed cert. Fail instead.
            if migrateFromKeychain, keyPEM == nil,
               !FileManager.default.fileExists(atPath: keyURL.path),
               KeychainStore.exists(account: keyAccount) {
                throw CAError.keyPresentButUnreadable
            }
            let (cert, key) = try Self.makeRootCA()
            caCertificate = cert
            caKey = key
            try cert.serializeAsPEM().pemString.write(to: certURL, atomically: true, encoding: .utf8)
            try Self.writeKeyFile(key.pemRepresentation, to: keyURL)
        }

        rootCertificatePEM = try caCertificate.serializeAsPEM().pemString
        caNIOCertificate = try NIOSSLCertificate(bytes: Array(rootCertificatePEM.utf8), format: .pem)
    }

    /// Write the CA private key to an owner-only (0600) file.
    private static func writeKeyFile(_ pem: String, to url: URL) throws {
        try pem.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A cached server-side TLS context presenting a leaf cert for `host`.
    func serverContext(forHost host: String) throws -> NIOSSLContext {
        lock.lock()
        if let cached = contextCache[host] { lock.unlock(); return cached }
        lock.unlock()

        let (leaf, leafKey) = try makeLeaf(forHost: host)
        let leafPEM = try leaf.serializeAsPEM().pemString
        let nioLeaf = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioLeaf), .certificate(caNIOCertificate)],
            privateKey: .privateKey(nioKey)
        )
        // Span TLS 1.2–1.3 so we interoperate with everything from old system
        // LibreSSL clients to modern Android/iOS. We only speak HTTP/1.1.
        config.minimumTLSVersion = .tlsv12
        config.maximumTLSVersion = .tlsv13
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)

        lock.lock(); contextCache[host] = context; lock.unlock()
        return context
    }

    func exportRootCertificate(to url: URL) throws {
        try rootCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Certificate minting

    private static func makeRootCA() throws -> (Certificate, P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName("Jaca Proxy CA")
            OrganizationName("Jaca")
        }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-86_400),
            // Very long-lived (≈30y): the root is minted once per Mac, persisted (cert on
            // disk + key in the Keychain) and reused across every device and every Jaca
            // update, so a cert the user installs keeps working for the life of the machine.
            notValidAfter: Date().addingTimeInterval(30 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return (cert, key)
    }

    private func makeLeaf(forHost host: String) throws -> (Certificate, P256.Signing.PrivateKey) {
        let leafKey = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName(host) }
        let san = try SubjectAlternativeNames([.dnsName(host)])
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: Date().addingTimeInterval(-86_400),
            notValidAfter: Date().addingTimeInterval(825 * 86_400),
            issuer: caCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                san
            },
            issuerPrivateKey: Certificate.PrivateKey(caKey)
        )
        return (cert, leafKey)
    }
}

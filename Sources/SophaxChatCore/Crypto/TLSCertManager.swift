// TLSCertManager.swift
// SophaxChatCore
//
// Generates an ephemeral per-session P-256 self-signed TLS certificate for
// use in the TCP transport layer.
//
// The certificate is NOT used for application identity — that role belongs to
// the Ed25519/X25519 keypairs managed by IdentityManager and verified via
// X3DH + Ed25519 signatures. The TLS layer closes the transport-metadata gap:
// without it, a network-path observer (ISP, router) can see IP-level social
// graph, message sizes, and timing even though application content is encrypted.
//
// A fresh P-256 key and certificate are generated on every app session.
// The private key is added to the Keychain temporarily (required to create
// a SecIdentity) and deleted on deinit. The certificate lives in memory only.
//
// The SHA-256 fingerprint of the DER certificate is included in PreKeyBundle
// (tlsCertFingerprint). When a peer connects outbound, they extract this
// fingerprint and verify the server cert against it — mutual pinning with
// no CA and no trust chain.

import Foundation
import Security
import CryptoKit

public final class TLSCertManager: @unchecked Sendable {

    // Keychain application tag for the ephemeral TLS private key.
    // One tag per install — cleaned up on every start() and deinit.
    private static let keychainTag = "com.sophax.tls.ephemeral"

    /// The session's SecIdentity (ephemeral key + self-signed cert).
    /// Assign to TCPTransport.tlsIdentity before calling TCPTransport.start().
    public private(set) var secIdentity: SecIdentity?

    /// SHA-256 fingerprint of the DER-encoded session certificate (32 bytes).
    /// Assign to PreKeyManager.tlsCertFingerprint so it propagates in PreKeyBundles.
    public private(set) var certFingerprint: Data?

    public init() {}

    deinit { deleteKeychainKey() }

    // MARK: - Public

    /// Generate a fresh P-256 key + self-signed certificate for this session.
    /// Call once at app start, before TCPTransport.start().
    ///
    /// Returns true on success. Failure is non-fatal — the transport falls back
    /// to plain TCP (still protected by application-layer ChaCha20-Poly1305).
    @discardableResult
    public func start() -> Bool {
        // Remove any stale key from a previous session (e.g. after a crash).
        deleteKeychainKey()

        let tag = Self.keychainTag.data(using: .utf8)!

        // 1. Generate P-256 private key directly in the Keychain.
        //    kSecAttrIsPermanent: true is required so SecIdentityCreateWithCertificate
        //    can locate the key via its public key when we present the certificate.
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String:  256,
            kSecAttrIsPermanent as String:    true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String:          "sophax-tls-session",
            kSecAttrAccessible as String:     kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var cfErr: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &cfErr),
              let pubKey  = SecKeyCopyPublicKey(privKey) else { return false }

        // Export public key as uncompressed X9.63 EC point: 0x04 ‖ x ‖ y (65 bytes).
        var exportErr: Unmanaged<CFError>?
        guard let x963Data = SecKeyCopyExternalRepresentation(pubKey, &exportErr) as Data?
        else { return false }

        // 2. Encode a minimal self-signed X.509v3 DER certificate and sign it.
        guard let certDER  = buildCert(publicKeyX963: Array(x963Data), signingKey: privKey),
              let secCert  = SecCertificateCreateWithData(nil, certDER as CFData)
        else { return false }

        // 3. Pair the in-memory cert with the Keychain key to form a SecIdentity.
        //    The Keychain locates the private key by matching its public key against
        //    the public key embedded in secCert.
        var identityRef: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, secCert, &identityRef) == errSecSuccess,
              let id = identityRef else { return false }

        secIdentity     = id
        certFingerprint = Data(SHA256.hash(data: certDER))
        return true
    }

    // MARK: - Private: minimal X.509v3 DER certificate

    private func buildCert(publicKeyX963: [UInt8], signingKey: SecKey) -> Data? {
        // OID byte sequences (value only; tag + length added by DERWriter.writeOID).
        let oidECDSASHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let oidPrime256v1:  [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        let oidCommonName:  [UInt8] = [0x55, 0x04, 0x03]

        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &serial)

        let now    = Date()
        let expire = Date(timeIntervalSinceNow: 365 * 24 * 3600)

        // Helper: Name ::= SEQUENCE { SET { SEQUENCE { OID(CN) UTF8String("sx") } } }
        let buildName: (inout DERWriter) -> Void = { w in
            w.writeSequence { seq in
                seq.writeSet { set in
                    set.writeSequence { atv in
                        atv.writeOID(oidCommonName)
                        atv.writeUTF8String("sx")
                    }
                }
            }
        }

        // TBSCertificate
        var tbs = DERWriter()

        // version [0] EXPLICIT INTEGER(2) → v3
        tbs.writeExplicit(tag: 0xA0) { v in v.writeInteger([0x02]) }

        // serialNumber
        tbs.writeInteger(serial)

        // signature AlgorithmIdentifier: ecdsa-with-SHA256 (no parameters — RFC 5758)
        tbs.writeSequence { $0.writeOID(oidECDSASHA256) }

        // issuer
        buildName(&tbs)

        // validity
        tbs.writeSequence { v in v.writeUTCTime(now); v.writeUTCTime(expire) }

        // subject (self-signed → same as issuer)
        buildName(&tbs)

        // subjectPublicKeyInfo
        tbs.writeSequence { spki in
            spki.writeSequence { algId in
                algId.writeOID(oidECPublicKey)
                algId.writeOID(oidPrime256v1)
            }
            // BIT STRING: 0x00 (zero unused bits) ‖ uncompressed EC point
            spki.writeBitString([0x00] + publicKeyX963)
        }

        let tbsBytes = tbs.bytes

        // Sign TBSCertificate with ECDSA-SHA256
        var signErr: Unmanaged<CFError>?
        guard let sigCF = SecKeyCreateSignature(
            signingKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbsBytes) as CFData,
            &signErr
        ) else { return nil }

        // Certificate = SEQUENCE { TBSCertificate, signatureAlgorithm, signatureValue }
        var cert = DERWriter()
        cert.writeSequence { c in
            c.writeRaw(tbsBytes)
            c.writeSequence { $0.writeOID(oidECDSASHA256) }
            c.writeBitString([0x00] + Array(sigCF as Data))
        }
        return Data(cert.bytes)
    }

    // MARK: - Private: Keychain cleanup

    private func deleteKeychainKey() {
        let tag = Self.keychainTag.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag
        ]
        SecItemDelete(query as CFDictionary)
        secIdentity     = nil
        certFingerprint = nil
    }
}

// MARK: - Minimal ASN.1 / DER writer (private to this file)

private struct DERWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeRaw(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func writeTLV(tag: UInt8, content: [UInt8]) {
        bytes.append(tag)
        appendLength(content.count)
        bytes.append(contentsOf: content)
    }

    private mutating func appendLength(_ len: Int) {
        if len < 0x80 {
            bytes.append(UInt8(len))
        } else if len < 0x100 {
            bytes.append(0x81)
            bytes.append(UInt8(len))
        } else {
            bytes.append(0x82)
            bytes.append(UInt8(len >> 8))
            bytes.append(UInt8(len & 0xFF))
        }
    }

    mutating func writeSequence(_ build: (inout DERWriter) -> Void) {
        var inner = DERWriter(); build(&inner)
        writeTLV(tag: 0x30, content: inner.bytes)
    }

    mutating func writeSet(_ build: (inout DERWriter) -> Void) {
        var inner = DERWriter(); build(&inner)
        writeTLV(tag: 0x31, content: inner.bytes)
    }

    /// Write a context-specific EXPLICIT wrapper tag (e.g. 0xA0 for [0]).
    mutating func writeExplicit(tag: UInt8, _ build: (inout DERWriter) -> Void) {
        var inner = DERWriter(); build(&inner)
        writeTLV(tag: tag, content: inner.bytes)
    }

    /// DER INTEGER: prepends 0x00 if high bit is set to keep value positive.
    mutating func writeInteger(_ value: [UInt8]) {
        var content = value
        if let first = content.first, first & 0x80 != 0 { content.insert(0x00, at: 0) }
        writeTLV(tag: 0x02, content: content)
    }

    mutating func writeOID(_ oid: [UInt8]) { writeTLV(tag: 0x06, content: oid) }

    mutating func writeUTF8String(_ s: String) { writeTLV(tag: 0x0C, content: Array(s.utf8)) }

    /// BIT STRING: caller must include the "unused bits" prefix byte (0x00 = none).
    mutating func writeBitString(_ bytes: [UInt8]) { writeTLV(tag: 0x03, content: bytes) }

    /// UTCTime: "YYMMDDHHMMSSZ" (13 bytes, tag 0x17).
    mutating func writeUTCTime(_ date: Date) {
        let fmt        = DateFormatter()
        fmt.dateFormat = "yyMMddHHmmss"
        fmt.timeZone   = TimeZone(abbreviation: "UTC")
        writeTLV(tag: 0x17, content: Array((fmt.string(from: date) + "Z").utf8))
    }
}

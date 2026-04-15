// X3DH.swift
// SophaxChatCore
//
// Extended Triple Diffie-Hellman (X3DH) key agreement protocol.
// Establishes a shared secret between two parties asynchronously —
// the initiating party (Alice) can compute the secret even before
// the responding party (Bob) is online.
//
// The shared secret seeds the Double Ratchet.
//
// Reference: https://signal.org/docs/specifications/x3dh/
//
// DH operations:
//   DH1 = DH(IK_A, SPK_B)  — identity auth
//   DH2 = DH(EK_A, IK_B)   — ephemeral x identity
//   DH3 = DH(EK_A, SPK_B)  — ephemeral x signed prekey
//   DH4 = DH(EK_A, OPK_B)  — ephemeral x one-time prekey (if available)
//   SK  = KDF(DH1 || DH2 || DH3 [|| DH4])

import Foundation
import CryptoKit

private extension SharedSecret {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

public enum X3DH {

    // MARK: - Sender (Alice)

    public struct SenderResult {
        /// The derived shared secret to seed the Double Ratchet.
        public let sharedSecret: SymmetricKey
        /// Alice's ephemeral public key — sent to Bob in the InitialMessage.
        public let ephemeralPublicKey: Data
        /// Which of Bob's one-time prekeys was used (if any) — sent to Bob.
        public let usedOneTimePreKeyId: UInt32?
        /// ML-KEM-768 encapsulated shared secret (iOS 18+ only; nil otherwise).
        /// Must be sent to Bob alongside the X3DH ephemeral key so he can reproduce
        /// the hybrid shared secret. nil = Bob has no PQ key or sender is on iOS < 18.
        public let pqEncapsulatedKey: Data?
        /// Which of Bob's ML-KEM-768 signed prekeys Alice used. Sent to Bob so he
        /// can look up the correct private key for decapsulation. nil = no PQ key used.
        public let usedPQPreKeyId: UInt32?
    }

    /// Perform X3DH as the initiating party (Alice).
    ///
    /// - Parameters:
    ///   - senderIdentity: Alice's DH identity key pair (IK_A)
    ///   - recipientBundle: Bob's published prekey bundle
    /// - Returns: Shared secret + ephemeral key info to send Bob
    public static func initiateSender(
        senderIdentity: DHKeyPair,
        recipientBundle: PreKeyBundle
    ) throws -> SenderResult {

        // 1. Validate bundle timestamp — only accept bundles from the past (not future-dated).
        // Using abs() here would wrongly accept bundles up to maxPreKeyBundleAge in the future.
        let bundleAge = Date().timeIntervalSince(recipientBundle.timestamp)
        guard bundleAge >= 0, bundleAge < CryptoConstants.maxPreKeyBundleAge else {
            throw SophaxError.stalePreKeyBundle
        }

        // 2. Verify signed prekey signature
        guard try recipientBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        // 3. Decode recipient keys
        let recipientIK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientBundle.dhIdentityKeyPublic)
        let recipientSPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientBundle.signedPreKeyPublic)

        // 4. Generate Alice's ephemeral key pair
        let ephemeralPair = DHKeyPair()

        // 5. DH computations
        // DH1 = DH(IK_A, SPK_B)
        let dh1 = try senderIdentity.privateKey.sharedSecretFromKeyAgreement(with: recipientSPK)
        // DH2 = DH(EK_A, IK_B)
        let dh2 = try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientIK)
        // DH3 = DH(EK_A, SPK_B)
        let dh3 = try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientSPK)

        var dhConcat = dh1.rawData + dh2.rawData + dh3.rawData

        var usedOTPKId: UInt32? = nil
        if let otpkData = recipientBundle.oneTimePreKeyPublic,
           let otpkId   = recipientBundle.oneTimePreKeyId {
            // DH4 = DH(EK_A, OPK_B)
            let recipientOPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpkData)
            dhConcat += try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientOPK).rawData
            usedOTPKId = otpkId
        }

        // 6. Post-quantum KEM contribution (iOS 18+ only).
        // If Bob advertised an ML-KEM-768 public key, encapsulate a fresh shared secret.
        // The resulting (pq_shared_secret, encapsulated_key) are mixed into the HKDF IKM
        // so an attacker needs to break BOTH the classical Curve25519 DH AND the PQ KEM.
        var pqSharedSecret: Data? = nil
        var pqEncapKey:     Data? = nil
        var usedPQPreKeyId: UInt32? = nil
        #if swift(>=6.2)
        if #available(iOS 19.0, macOS 26.0, *),
           let pqPubData = recipientBundle.pqPreKeyPublic,
           let recipientPQKey = try? MLKEM768.PublicKey(rawRepresentation: pqPubData),
           let encResult = try? recipientPQKey.encapsulate() {
            pqSharedSecret = encResult.sharedSecret.withUnsafeBytes { Data($0) }
            pqEncapKey     = encResult.encapsulated
            usedPQPreKeyId = recipientBundle.pqPreKeyId   // nil for legacy identity-level keys
        }
        #endif

        // 7. Derive shared secret via HKDF, then zero the DH material immediately.
        let sharedSecret = try deriveSharedSecret(from: dhConcat, pqSharedSecret: pqSharedSecret)
        dhConcat.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        pqSharedSecret?.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }

        return SenderResult(
            sharedSecret:        sharedSecret,
            ephemeralPublicKey:  ephemeralPair.publicKeyData,
            usedOneTimePreKeyId: usedOTPKId,
            pqEncapsulatedKey:   pqEncapKey,
            usedPQPreKeyId:      usedPQPreKeyId
        )
    }

    // MARK: - Receiver (Bob)

    /// Perform X3DH as the receiving party (Bob).
    ///
    /// - Parameters:
    ///   - recipientIdentityDH: Bob's DH identity key pair (IK_B)
    ///   - recipientSignedPreKey: Bob's signed prekey pair (SPK_B) — used in X3DH
    ///   - recipientOneTimePreKey: Bob's one-time prekey pair (OPK_B) — if Alice used one
    ///   - senderIdentityDHKeyData: Alice's DH identity public key (IK_A)
    ///   - senderEphemeralKeyData: Alice's ephemeral public key (EK_A) from the message
    ///   - senderPQEncapsulatedKey: Alice's ML-KEM-768 encapsulated key (nil if Alice is on iOS < 18)
    ///   - recipientPQPreKey: Bob's ML-KEM-768 prekey as `integrityCheckedRepresentation` bytes.
    ///     Pass the rotating PQ signed prekey (looked up by `usedPQPreKeyId`). nil = skip PQ decap.
    /// - Returns: Shared secret (must match Alice's)
    public static func initiateReceiver(
        recipientIdentityDH: DHKeyPair,
        recipientSignedPreKey: DHKeyPair,
        recipientOneTimePreKey: DHKeyPair?,
        senderIdentityDHKeyData: Data,
        senderEphemeralKeyData: Data,
        senderPQEncapsulatedKey: Data? = nil,
        recipientPQPreKey: Data?       = nil
    ) throws -> SymmetricKey {

        let senderIK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderIdentityDHKeyData)
        let senderEK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderEphemeralKeyData)

        // DH1 = DH(SPK_B, IK_A)   [symmetric to Alice's DH1]
        let dh1 = try recipientSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: senderIK)
        // DH2 = DH(IK_B, EK_A)
        let dh2 = try recipientIdentityDH.privateKey.sharedSecretFromKeyAgreement(with: senderEK)
        // DH3 = DH(SPK_B, EK_A)
        let dh3 = try recipientSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: senderEK)

        var dhConcat = dh1.rawData + dh2.rawData + dh3.rawData

        if let otp = recipientOneTimePreKey {
            // DH4 = DH(OPK_B, EK_A)
            dhConcat += try otp.privateKey.sharedSecretFromKeyAgreement(with: senderEK).rawData
        }

        // Post-quantum contribution: decapsulate Alice's ML-KEM-768 ciphertext (iOS 19+ only).
        // `recipientPQPreKey` is the rotating PQ signed prekey (integrityCheckedRepresentation).
        // If the ID didn't match Bob's current key (rotation happened), the caller passes nil
        // and the PQ layer is skipped — session falls back to classical security for this exchange.
        var pqSharedSecret: Data? = nil
        #if swift(>=6.2)
        if #available(iOS 19.0, macOS 26.0, *),
           let encapData  = senderPQEncapsulatedKey,
           let pqKeyBytes = recipientPQPreKey,
           let pqPrivKey  = try? MLKEM768.PrivateKey(integrityCheckedRepresentation: pqKeyBytes) {
            let pqSS = try pqPrivKey.decapsulate(encapData)
            pqSharedSecret = pqSS.withUnsafeBytes { Data($0) }
        }
        #endif

        let sharedSecret = try deriveSharedSecret(from: dhConcat, pqSharedSecret: pqSharedSecret)
        dhConcat.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        pqSharedSecret?.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        return sharedSecret
    }

    // MARK: - KDF

    /// HKDF-SHA256 key derivation.
    /// Follows the Signal X3DH spec: F || DH_concat is the IKM,
    /// where F = 32 bytes of 0xFF (domain separator for non-empty use).
    ///
    /// When `pqSharedSecret` is non-nil (hybrid mode), it is appended to the IKM
    /// after the DH material. HKDF's extraction step mixes all of it securely —
    /// the session key is secure as long as either the classical DH OR the PQ KEM is secure.
    private static func deriveSharedSecret(from dhConcat: Data, pqSharedSecret: Data? = nil) throws -> SymmetricKey {
        guard dhConcat.count == 96 || dhConcat.count == 128 else {
            throw SophaxError.keyAgreementFailed
        }
        // Per Signal X3DH spec: prepend 32 0xFF bytes as domain separator
        let f    = Data(repeating: 0xFF, count: 32)
        var ikm  = f + dhConcat
        // Append PQ contribution when available — length differs from classical-only
        // IKM, which inherently domain-separates hybrid from non-hybrid derives.
        if let pq = pqSharedSecret {
            ikm += pq
        }
        let salt = Data(repeating: 0x00, count: 32)   // 32 zero bytes as salt

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: CryptoConstants.x3dhInfo,
            outputByteCount: 32
        )
    }
}

// Keccak.swift
// SophaxChatCore
//
// Minimal Keccak-256 (SHA3-256) implementation.
// Used solely for Tor v3 .onion address checksum derivation.
// Based on the NIST SHA-3 standard (FIPS 202).

import Foundation

enum Keccak {

    // MARK: - Public API

    /// Computes the Keccak-256 (SHA3-256) digest of the given data.
    static func hash256(_ input: Data) -> Data {
        var state = State()
        absorb(&state, input: input, rate: rate256, suffix: domainSuffix256)
        return squeeze(&state, outputLength: 32, rate: rate256)
    }

    // MARK: - Constants

    private static let rate256      = 136   // bytes (1088 bits), r = 1600 - 2*256
    private static let domainSuffix256: UInt8 = 0x06   // SHA3 domain separation

    // MARK: - State

    private struct State {
        var lanes: [UInt64] = Array(repeating: 0, count: 25)
    }

    // MARK: - Absorb

    private static func absorb(_ state: inout State, input: Data, rate: Int, suffix: UInt8) {
        var buf = Array(input)
        // Pad with SHA3 multi-rate padding: append suffix, then zeros, then 0x80
        buf.append(suffix)
        while buf.count % rate != 0 {
            buf.append(0x00)
        }
        buf[buf.count - 1] |= 0x80

        var offset = 0
        while offset < buf.count {
            for i in 0 ..< (rate / 8) {
                let lo = offset + i * 8
                let slice = buf[lo ..< lo + 8]
                let lane  = slice.withUnsafeBytes { $0.load(as: UInt64.self) }  // little-endian
                state.lanes[i] ^= lane
            }
            keccakF(&state)
            offset += rate
        }
    }

    // MARK: - Squeeze

    private static func squeeze(_ state: inout State, outputLength: Int, rate: Int) -> Data {
        var out = Data()
        var remaining = outputLength
        while remaining > 0 {
            let take = min(remaining, rate)
            for i in 0 ..< (take + 7) / 8 {
                var lane = state.lanes[i]
                withUnsafeBytes(of: &lane) { out.append(contentsOf: $0) }
            }
            remaining -= take
            if remaining > 0 { keccakF(&state) }
        }
        return out.prefix(outputLength)
    }

    // MARK: - Keccak-f[1600] permutation

    private static func keccakF(_ state: inout State) {
        let roundConstants: [UInt64] = [
            0x0000000000000001, 0x0000000000008082,
            0x800000000000808a, 0x8000000080008000,
            0x000000000000808b, 0x0000000080000001,
            0x8000000080008081, 0x8000000000008009,
            0x000000000000008a, 0x0000000000000088,
            0x0000000080008009, 0x000000008000000a,
            0x000000008000808b, 0x800000000000008b,
            0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080,
            0x000000000000800a, 0x800000008000000a,
            0x8000000080008081, 0x8000000000008080,
            0x0000000080000001, 0x8000000080008008,
        ]
        let rho: [Int] = [
             1,  3,  6, 10, 15, 21, 28, 36, 45, 55,
             2, 14, 27, 41, 56,  8, 25, 43, 62, 18,
            39, 61, 20, 44,
        ]
        let pi: [Int] = [
            10,  7, 11, 17, 18,
             3,  5, 16,  8, 21,
            24,  4, 15, 23, 19,
            13, 12,  2, 20, 14,
             1,  6, 22, 25,  9,
        ]

        var lanes = state.lanes
        for rc in roundConstants {
            // θ
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0 ..< 5 {
                c[x] = lanes[x] ^ lanes[x+5] ^ lanes[x+10] ^ lanes[x+15] ^ lanes[x+20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0 ..< 5 {
                d[x] = c[(x+4)%5] ^ rotl(c[(x+1)%5], by: 1)
            }
            for i in 0 ..< 25 { lanes[i] ^= d[i % 5] }

            // ρ and π
            var b = [UInt64](repeating: 0, count: 25)
            b[0] = lanes[0]
            for (i, lane) in lanes[1...].enumerated() {
                let rotated = rotl(lane, by: rho[i])
                b[pi[i] - 1] = rotated
            }

            // χ
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0 ..< 5 {
                    lanes[y+x] = b[y+x] ^ (~b[y + (x+1)%5] & b[y + (x+2)%5])
                }
            }

            // ι
            lanes[0] ^= rc
        }
        state.lanes = lanes
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, by n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}

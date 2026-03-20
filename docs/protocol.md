# SophaxChat Wire Protocol

All messages are JSON-encoded and sent over the P2P mesh (MultipeerConnectivity on iOS, Nearby Connections on Android) or over TCP/Tor.

## Transport

Every message is wrapped in a `WireMessage` envelope, signed with the sender's Ed25519 identity key.

### WireMessage

```json
{
  "type":      "message",
  "payload":   "<base64-encoded JSON of the inner message>",
  "senderID":  "<peerID — SHA-256(signingKey || dhKey) hex>",
  "timestamp": "2025-01-01T00:00:00Z",
  "signature": "<base64 Ed25519 signature>"
}
```

**Signing bytes** (deterministic, no extra Date() call):
```
type.rawValue.utf8 || payload || senderID.utf8 || ISO8601(timestamp).utf8
```

---

## Message Types

| `type` | Inner struct | Direction | Encrypted |
|--------|-------------|-----------|-----------|
| `hello` | `HelloMessage` | peer ↔ peer | No (public keys) |
| `initiateSession` | `InitiateSessionMessage` | A → B | Partial (X3DH) |
| `message` | `ChatMessagePayload` | A ↔ B | Yes (Double Ratchet) |
| `ack` | `AckMessage` | B → A | No |
| `relay` | `RelayEnvelope` | any → any | Inner only |
| `typing` | `TypingMessage` | A → B | No |
| `sealed` | `SealedMessage` | A → B | Yes (ChaCha20-Poly1305) |
| `readReceipt` | `ReadReceiptMessage` | B → A | No |
| `reaction` | `ReactionMessage` | A → B | No |
| `groupMessage` | `GroupWireMessage` | A → members | Yes (Sender Keys) |
| `groupReaction` | `GroupReactionMessage` | any → members | No |
| `groupMemberLeft` | `GroupMemberLeftMessage` | leaver → members | No |
| `groupReadReceipt` | `GroupReadReceiptMessage` | receiver → sender | No |
| `storeAndForward` | `StoreAndForwardRequest` | A → relay | Outer no, inner sealed |
| `storeAndForwardDelivery` | `StoreAndForwardDelivery` | relay → B | Sealed items |
| `channelAnnouncement` | `ChannelAnnouncement` | creator → mesh | No |

---

## Protocol Flow

### 1. Discovery + Handshake

```
A connects to B (MPC/Nearby/TCP)
A → B: hello  { bundle: PreKeyBundle }
B → A: hello  { bundle: PreKeyBundle }
```

**PreKeyBundle** contains:
- `peerID` — `hex(SHA-256(signingKey || dhKey))[0..<16]`
- `username`
- `signingKeyPublic` — Ed25519 (32 bytes, base64)
- `dhIdentityKeyPublic` — X25519 (32 bytes, base64)
- `signedPreKeyPublic` / `signedPreKeyId` / `signedPreKeySignature`
- `oneTimePreKeys` — array of `{ id, publicKey }` (optional)
- `tcpAddress` — `"host:port"` if peer advertises a Tor/TCP address (optional)

### 2. Session Initiation (X3DH)

Alice sends the first message:

```
A → B: initiateSession {
  senderBundle:        PreKeyBundle,
  ephemeralPublicKey:  Data,           // EK_A (32 bytes)
  usedSignedPreKeyId:  UInt32,
  usedOneTimePreKeyId: UInt32?,
  initialMessage:      RatchetMessage  // first DR message
}
```

Bob derives the shared secret using X3DH and initialises the Double Ratchet as responder.

### 3. Normal Messages

```
A → B: message {
  ratchetMessage: RatchetMessage,
  messageID: "UUID"
}
```

**RatchetMessage**:
```json
{
  "header": {
    "dhPublicKey": "<base64>",
    "previousChainLength": 0,
    "messageNumber": 0
  },
  "ciphertext": "<base64 ChaCha20-Poly1305>"
}
```

**MessageContent** (plaintext inside ciphertext):
```json
{
  "body":               "Hello!",
  "type":               "text",
  "replyToID":          null,
  "timestamp":          "2025-01-01T00:00:00Z",
  "expiresAt":          null,
  "attachmentData":     null,
  "attachmentMimeType": null,
  "audioDuration":      null,
  "groupInviteData":    null,
  "senderKeyData":      null
}
```

`type` values: `text` | `image` | `audio` | `groupInvite` | `senderKeyDistribution`

### 4. Delivery Ack

```
B → A: ack { messageID: "UUID", status: "delivered" }
```

### 5. Multihop Relay

```
A → C: relay { RelayEnvelope }
C → B: relay { RelayEnvelope (ttl-1, hopCount+1) }
```

**RelayEnvelope**:
```json
{
  "id":           "UUID",
  "targetPeerID": "abc123",
  "originPeerID": "xyz789",
  "ttl":          5,
  "hopCount":     1,
  "message":      { WireMessage }
}
```

Max TTL = 6. Nodes drop envelopes with TTL = 0. Deduplication via LRU cache of envelope IDs.

### 6. Sealed Sender

Hides the inner message type and payload from relay nodes:

```
encryption:
  EK_s = random Curve25519 keypair
  sharedSecret = ECDH(EK_s.private, recipient.dhPublicKey)
  sealingKey = HKDF-SHA256(sharedSecret, info="SophaxChat_SealedSender_v1", len=32)
  encryptedPayload = ChaCha20-Poly1305(sealingKey, JSON(innerWireMessage))
```

```json
sealed {
  "ephemeralPublicKey": "<base64 32B>",
  "encryptedPayload":   "<base64 nonce(12B) + ciphertext + tag(16B)>"
}
```

### 7. Group Messages (Sender Keys v2)

Each group member maintains a KDF chain. Messages use a per-message key derived at the current chain iteration:

```
message_key = HKDF-SHA256(chain_key, info="SophaxChat_SenderKey_Message_v1", len=32)
next_chain_key = HKDF-SHA256(chain_key, info="SophaxChat_SenderKey_Chain_v1", len=32)
```

**GroupWireMessage**:
```json
{
  "groupID":              "UUID",
  "messageID":            "UUID",
  "senderPeerID":         "abc123",
  "senderUsername":       "alice",
  "timestamp":            "2025-01-01T00:00:00Z",
  "ciphertext":           "<base64 ChaChaPoly>",
  "attachmentCiphertext": null,
  "attachmentMimeType":   null,
  "audioDuration":        null,
  "senderKeyIteration":   42,
  "expiresAt":            null,
  "replyToID":            null
}
```

`senderKeyIteration = nil` → v1 shared-key (backward compat).

---

## Store-and-Forward (Offline Delivery)

When target is offline, Alice asks a directly-connected relay peer Bob to hold a sealed message:

```
A → B: storeAndForward {
  targetPeerID: "carol_id",
  messageID:    "UUID",
  sealed:       SealedMessage,
  expiresAt:    "2025-01-02T00:00:00Z"
}
```

When Carol connects to Bob:
```
B → Carol: storeAndForwardDelivery {
  items: [ { messageID, sealed }, ... ]
}
```

---

## PeerID Derivation

```
peerID = hex(SHA-256(signingKeyPublic || dhIdentityKeyPublic))[0..<16]
```

Both keys are 32-byte raw representations (no ASN.1 wrapper).

---

## Versioning

The protocol is currently unversioned. Breaking changes will be introduced via a new `WireMessageType` value or a `version` field in the `WireMessage` envelope.

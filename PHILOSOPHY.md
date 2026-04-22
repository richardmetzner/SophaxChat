# The SophaxChat Philosophy

> **Every commit to this repository is a vote for a specific vision of the internet. Read this before you contribute.**

---

## The Problem with Centralization

Most software infrastructure is organized around a central point: a company, a server, an account. This is not a neutral technical choice. It is a political one.

A central server is a point of control. It decides who can communicate and who cannot. It is a point of surveillance — every message that flows through it can be logged, analyzed, and sold. It is a point of failure — take it down, and the service dies. And it is a point of coercion: governments and courts know exactly where to send the subpoena.

The companies that run these servers will tell you they care about your privacy. Some of them believe it. It does not matter. A system that *could* betray you *will* betray you — if not today, then when the company is acquired, when the jurisdiction changes, when the national security letter arrives, when the executive team decides that user data is an asset worth monetizing. Good intentions do not survive contact with power.

This is not paranoia. It is the observable history of every large communication platform.

---

## The Only Honest Answer

If centralization is the problem, decentralization is the only honest answer — not as a feature, not as a marketing claim, but as an architectural constraint that cannot be bypassed even if we wanted to.

SophaxChat does not connect to any server. Not because we haven't built one yet. Not because we're saving it for later. Because **the absence of a server is the security guarantee**. There is no server to subpoena. No database to breach. No company to pressure. No infrastructure to shut down.

This means some things are harder. You cannot receive a message when your device is off. You cannot look up a contact by username in a central directory. You cannot recover your account if you lose your keys. These are not bugs — they are the correct tradeoffs. The inconvenience is the security.

---

## The Principles

These are not guidelines. They are the boundary conditions of the project. A contribution that violates them is not a contribution that needs a different implementation — it is a contribution that is out of scope.

### 1. No servers, ever.

Communication happens directly between devices: over Bluetooth LE, over WiFi Direct, over peer-to-peer TCP. The Tor network (via Orbot) provides internet routing without introducing any trusted server — your traffic is anonymized by the network, not routed through ours.

If a feature requires a server to function — even a "temporary" one, even one you self-host, even one that only stores metadata — it does not belong in SophaxChat.

### 2. No identity leakage.

Your identity in SophaxChat is a Curve25519 key pair, generated on your device, never transmitted to any server, never linked to a phone number, email address, or any real-world identifier unless you choose to provide one. The app does not ask for your name. It does not know your location. It cannot connect you to any account.

A feature that requires — or even encourages — users to link their cryptographic identity to a real-world identity undermines this principle. That includes "optional" account recovery through a phone number, cloud backup of identity keys, and any telemetry that could fingerprint a device.

### 3. Maximum cryptographic protection, not "good enough."

SophaxChat implements the Signal Protocol in full: X3DH for session establishment, Double Ratchet with Header Encryption for messaging, Sealed Sender for sender anonymity. These are not features we added because they were easy. They are the result of decades of academic and engineering work on what forward secrecy and break-in recovery actually require.

"Good enough" crypto is not good enough. AES with a static key is not good enough. TLS to a server you control is not good enough. If a simpler approach would also provide "mostly fine" security, the answer is still no — because "mostly fine" fails exactly when it matters most.

### 4. Minimal dependencies.

Every external dependency is an attack surface, a supply chain risk, and a maintenance burden. The codebase uses Apple's CryptoKit for all cryptographic primitives — hardware-accelerated, independently audited, and controlled by the OS vendor rather than a third party. New dependencies require justification proportional to the security implications.

"It saves time" is not sufficient justification. "There is no other way to achieve this security property" is.

### 5. Open, auditable code.

Security that cannot be verified is not security — it is a claim. Every line of cryptographic code in SophaxChat must be readable, understandable, and testable by anyone. This means no obfuscation, no security-through-obscurity, no "trust us." The ~3,500 lines of cryptographic Swift in this repository exist to be read, critiqued, and improved.

---

## What This Means for Contributors

Contributing to SophaxChat is not just writing code. It is agreeing to a set of constraints that exist for reasons that matter to real people in real danger.

**Journalists** use tools like this to communicate with sources in environments where being identified means imprisonment or worse. **Activists** use them in countries where the message metadata — who talked to whom, when, how often — is as dangerous as the message content. **Disaster responders** use them when the infrastructure has collapsed and Bluetooth is the only network left. These are not hypothetical users. They are the reason the design decisions in this codebase are not negotiable.

When you submit a pull request, you are implicitly agreeing that:

- Your change does not introduce a server dependency, even temporarily or optionally.
- Your change does not weaken any existing cryptographic guarantee.
- Your change does not add any mechanism for identity linkage or tracking.
- Your change is auditable — the security properties can be verified by reading the code.
- Your change treats the principles above as hard constraints, not starting points for negotiation.

If your proposed change is in tension with any of these, the right response is to open an issue and discuss it — not to find a way around it.

---

## The Bigger Picture

SophaxChat is not just a chat app. It is a working demonstration that Signal-grade cryptography and zero infrastructure are compatible. That you do not have to choose between security and usability. That decentralized software can be made that normal people can run on devices they already own.

Every feature that ships, every bug that is fixed, every security issue that is addressed responsibly makes that demonstration more credible.

The goal is not market share. The goal is to exist — clearly documented, publicly auditable, and genuinely useful — so that when someone needs a tool that cannot betray them, there is one.

---

## Further Reading

- [README.md](README.md) — full feature list, protocol overview, cryptographic primitive table
- [docs/crypto.md](docs/crypto.md) — detailed cryptographic design
- [docs/protocol.md](docs/protocol.md) — wire protocol specification
- [THREAT_MODEL.md](THREAT_MODEL.md) — what we defend against, and what we do not
- [SECURITY.md](SECURITY.md) — responsible disclosure and known findings
- [CONTRIBUTING.md](.github/CONTRIBUTING.md) — build instructions and contribution process

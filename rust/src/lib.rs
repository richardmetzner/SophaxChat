// sophax_mls — MLS (RFC 9420) wrapper for SophaxChat
//
// Pure-Rust RustCrypto backend — no OpenSSL, iOS-compatible.
// Stateless design: every function takes serialized group state, performs one
// operation, returns new serialized state. Swift owns persistence.

use std::collections::HashSet;
use std::sync::Arc;

use mls_rs::{
    identity::{
        basic::{BasicCredential, BasicIdentityProvider},
        SigningIdentity,
    },
    storage_provider::in_memory::InMemoryGroupStateStorage,
    CipherSuite, CipherSuiteProvider, Client, CryptoProvider, ExtensionList, MlsMessage,
};
use mls_rs_core::{
    crypto::{SignaturePublicKey, SignatureSecretKey},
    group::{GroupState, GroupStateStorage},
};
use mls_rs_crypto_rustcrypto::RustCryptoProvider;

uniffi::setup_scaffolding!();

const CIPHER_SUITE: CipherSuite = CipherSuite::CURVE25519_AES128;

// ───────────────────────────────────────────────────────────────────── Errors

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum MlsError {
    #[error("{msg}")]
    Protocol { msg: String },
    #[error("Decryption failed or message type is not application data")]
    DecryptionFailed,
    #[error("{msg}")]
    InvalidState { msg: String },
    #[error("{msg}")]
    Serialization { msg: String },
    #[error("Member not found in roster")]
    UnknownMember,
    #[error("Expected a Commit message")]
    InvalidCommit,
}

impl From<mls_rs::error::MlsError> for MlsError {
    fn from(e: mls_rs::error::MlsError) -> Self {
        MlsError::Protocol { msg: e.to_string() }
    }
}

// ──────────────────────────────────────────────────────────────────── Records

#[derive(Debug, Clone, uniffi::Record)]
pub struct MemberWelcome {
    pub peer_id: String,
    pub welcome_bytes: Vec<u8>,
    /// Ratchet tree bytes — send alongside welcome for clients without tree extension
    pub ratchet_tree_bytes: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CreateGroupOutput {
    /// Coordinator's group state — persist encrypted immediately
    pub group_state: Vec<u8>,
    /// One Welcome per invited member; send via DR unicast
    pub welcomes: Vec<MemberWelcome>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitOutput {
    /// Broadcast to all group members
    pub commit_bytes: Vec<u8>,
    /// Send to new member (present only for AddMember commits)
    pub welcome_bytes: Option<Vec<u8>>,
    /// Updated state — replace persisted state after distributing commit
    pub new_group_state: Vec<u8>,
    pub new_epoch: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProcessedCommit {
    pub added_peer_ids: Vec<String>,
    pub removed_peer_ids: Vec<String>,
    pub new_group_state: Vec<u8>,
    pub new_epoch: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EncryptOutput {
    pub ciphertext: Vec<u8>,
    pub new_group_state: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DecryptOutput {
    pub plaintext: Vec<u8>,
    pub new_group_state: Vec<u8>,
}

// ─────────────────────────────────────────────────────────── MlsClientHandle

/// Local MLS identity derived from the peer's existing Ed25519 key.
#[derive(uniffi::Object)]
pub struct MlsClientHandle {
    peer_id: String,
    signing_secret: Vec<u8>,
    crypto: RustCryptoProvider,
}

#[uniffi::export]
impl MlsClientHandle {
    #[uniffi::constructor]
    pub fn new(peer_id: String, signing_key_bytes: Vec<u8>) -> Result<Arc<Self>, MlsError> {
        if signing_key_bytes.len() != 32 {
            return Err(MlsError::InvalidState {
                msg: format!("signing key must be 32 bytes, got {}", signing_key_bytes.len()),
            });
        }
        Ok(Arc::new(MlsClientHandle {
            peer_id,
            signing_secret: signing_key_bytes,
            crypto: RustCryptoProvider::default(),
        }))
    }

    /// Generate a fresh single-use KeyPackage for this identity.
    pub fn generate_key_package(&self) -> Result<Vec<u8>, MlsError> {
        let client = self.make_client(InMemoryGroupStateStorage::new())?;
        let kp = client
            .generate_key_package_message(Default::default(), Default::default(), None)
            .map_err(MlsError::from)?;
        kp.to_bytes()
            .map_err(|e| MlsError::Serialization { msg: e.to_string() })
    }
}

impl MlsClientHandle {
    /// Build a ready-to-use MLS client, seeded with the provided group state storage.
    /// `Client::builder()` starts from `BaseConfig` which already includes in-memory
    /// key-package, PSK, and group-state storage + DefaultMlsRules. We override only
    /// the group-state storage (to use our pre-seeded instance) and supply the identity.
    fn make_client(&self, group_storage: InMemoryGroupStateStorage) -> Result<Client<impl mls_rs::client_builder::MlsConfig>, MlsError> {
        let cs = self.crypto.cipher_suite_provider(CIPHER_SUITE).ok_or_else(|| {
            MlsError::InvalidState { msg: "cipher suite unavailable".to_string() }
        })?;
        let secret = SignatureSecretKey::from(self.signing_secret.clone());
        let public: SignaturePublicKey = cs
            .signature_key_derive_public(&secret)
            .map_err(|e| MlsError::InvalidState { msg: e.to_string() })?;
        let credential = BasicCredential::new(self.peer_id.as_bytes().to_vec());
        let signing_identity = SigningIdentity::new(credential.into_credential(), public);
        Ok(Client::builder()
            .identity_provider(BasicIdentityProvider)
            .crypto_provider(self.crypto.clone())
            .group_state_storage(group_storage)
            .signing_identity(signing_identity, secret, CIPHER_SUITE)
            .build())
    }
}

// ──────────────────────────────────────────────────────── Free functions

/// Create a new MLS group (coordinator only).
#[uniffi::export]
pub fn mls_create_group(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    member_key_packages: Vec<Vec<u8>>,
) -> Result<CreateGroupOutput, MlsError> {
    let gs = InMemoryGroupStateStorage::new();
    let c = client.make_client(gs.clone())?;
    let mut group = c
        .create_group_with_id(group_id.clone(), ExtensionList::default(), Default::default(), None)
        .map_err(MlsError::from)?;

    let mut welcomes = Vec::new();
    for kp_bytes in member_key_packages {
        let kp = MlsMessage::from_bytes(&kp_bytes)
            .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
        let peer_id = peer_id_from_key_package(&kp)?;
        let commit = group.commit_builder().add_member(kp).map_err(MlsError::from)?.build().map_err(MlsError::from)?;
        group.apply_pending_commit().map_err(MlsError::from)?;
        let welcome_bytes = commit.welcome_messages.into_iter().next()
            .ok_or_else(|| MlsError::InvalidState { msg: "no welcome message".to_string() })?
            .to_bytes().map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
        let ratchet_tree_bytes = group.export_tree().to_bytes()
            .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
        welcomes.push(MemberWelcome { peer_id, welcome_bytes, ratchet_tree_bytes });
    }

    group.write_to_storage().map_err(MlsError::from)?;
    let group_state = extract_state(&gs, &group_id)?;
    Ok(CreateGroupOutput { group_state, welcomes })
}

/// Join a group by processing a Welcome message.
#[uniffi::export]
pub fn mls_process_welcome(
    client: Arc<MlsClientHandle>,
    welcome_bytes: Vec<u8>,
    ratchet_tree_bytes: Option<Vec<u8>>,
) -> Result<Vec<u8>, MlsError> {
    let gs = InMemoryGroupStateStorage::new();
    let c = client.make_client(gs.clone())?;
    let welcome = MlsMessage::from_bytes(&welcome_bytes)
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let ratchet_tree = ratchet_tree_bytes
        .as_deref()
        .map(|bytes| mls_rs::group::ExportedTree::from_bytes(bytes))
        .transpose()
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let (mut group, _) = c.join_group(ratchet_tree, &welcome, None).map_err(MlsError::from)?;
    group.write_to_storage().map_err(MlsError::from)?;
    let group_id = group.group_id().to_vec();
    extract_state(&gs, &group_id)
}

/// Encrypt an application message.
#[uniffi::export]
pub fn mls_encrypt(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    group_state: Vec<u8>,
    plaintext: Vec<u8>,
) -> Result<EncryptOutput, MlsError> {
    let mut gs = InMemoryGroupStateStorage::new();
    seed_storage(&mut gs, &group_id, group_state)?;
    let c = client.make_client(gs.clone())?;
    let mut group = c.load_group(&group_id).map_err(MlsError::from)?;
    let msg = group.encrypt_application_message(&plaintext, Default::default()).map_err(MlsError::from)?;
    let ciphertext = msg.to_bytes().map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    group.write_to_storage().map_err(MlsError::from)?;
    let new_group_state = extract_state(&gs, &group_id)?;
    Ok(EncryptOutput { ciphertext, new_group_state })
}

/// Decrypt an MLS application message.
#[uniffi::export]
pub fn mls_decrypt(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    group_state: Vec<u8>,
    ciphertext: Vec<u8>,
) -> Result<DecryptOutput, MlsError> {
    let mut gs = InMemoryGroupStateStorage::new();
    seed_storage(&mut gs, &group_id, group_state)?;
    let c = client.make_client(gs.clone())?;
    let mut group = c.load_group(&group_id).map_err(MlsError::from)?;
    let msg = MlsMessage::from_bytes(&ciphertext)
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let received = group.process_incoming_message(msg).map_err(MlsError::from)?;
    let plaintext = match received {
        mls_rs::group::ReceivedMessage::ApplicationMessage(app_msg) => app_msg.data().to_vec(),
        _ => return Err(MlsError::DecryptionFailed),
    };
    group.write_to_storage().map_err(MlsError::from)?;
    let new_group_state = extract_state(&gs, &group_id)?;
    Ok(DecryptOutput { plaintext, new_group_state })
}

/// Process a Commit broadcast (coordinator's output). Validates coordinator in Swift.
#[uniffi::export]
pub fn mls_process_commit(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    group_state: Vec<u8>,
    commit_bytes: Vec<u8>,
) -> Result<ProcessedCommit, MlsError> {
    let mut gs = InMemoryGroupStateStorage::new();
    seed_storage(&mut gs, &group_id, group_state)?;
    let c = client.make_client(gs.clone())?;
    let mut group = c.load_group(&group_id).map_err(MlsError::from)?;

    // Snapshot current roster before commit
    let before: HashSet<String> = roster_peer_ids(&group);

    let msg = MlsMessage::from_bytes(&commit_bytes)
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let received = group.process_incoming_message(msg).map_err(MlsError::from)?;
    match received {
        mls_rs::group::ReceivedMessage::Commit(_) => {}
        _ => return Err(MlsError::InvalidCommit),
    };

    let after: HashSet<String> = roster_peer_ids(&group);
    let added_peer_ids: Vec<String> = after.difference(&before).cloned().collect();
    let removed_peer_ids: Vec<String> = before.difference(&after).cloned().collect();
    let new_epoch = group.current_epoch();

    group.write_to_storage().map_err(MlsError::from)?;
    let new_group_state = extract_state(&gs, &group_id)?;
    Ok(ProcessedCommit { added_peer_ids, removed_peer_ids, new_group_state, new_epoch })
}

/// Add a member (coordinator only). Returns commit to broadcast + welcome to send.
#[uniffi::export]
pub fn mls_add_member(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    group_state: Vec<u8>,
    key_package_bytes: Vec<u8>,
) -> Result<CommitOutput, MlsError> {
    let mut gs = InMemoryGroupStateStorage::new();
    seed_storage(&mut gs, &group_id, group_state)?;
    let c = client.make_client(gs.clone())?;
    let mut group = c.load_group(&group_id).map_err(MlsError::from)?;
    let kp = MlsMessage::from_bytes(&key_package_bytes)
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let commit = group.commit_builder().add_member(kp).map_err(MlsError::from)?.build().map_err(MlsError::from)?;
    group.apply_pending_commit().map_err(MlsError::from)?;
    let commit_bytes = commit.commit_message.to_bytes()
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let welcome_bytes = commit.welcome_messages.into_iter().next()
        .map(|w| w.to_bytes())
        .transpose()
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let new_epoch = group.current_epoch();
    group.write_to_storage().map_err(MlsError::from)?;
    let new_group_state = extract_state(&gs, &group_id)?;
    Ok(CommitOutput { commit_bytes, welcome_bytes, new_group_state, new_epoch })
}

/// Remove a member (coordinator only).
#[uniffi::export]
pub fn mls_remove_member(
    client: Arc<MlsClientHandle>,
    group_id: Vec<u8>,
    group_state: Vec<u8>,
    peer_id: String,
) -> Result<CommitOutput, MlsError> {
    let mut gs = InMemoryGroupStateStorage::new();
    seed_storage(&mut gs, &group_id, group_state)?;
    let c = client.make_client(gs.clone())?;
    let mut group = c.load_group(&group_id).map_err(MlsError::from)?;
    let peer_id_bytes = peer_id.as_bytes().to_vec();
    let leaf_index = group.roster().members_iter()
        .find(|m| m.signing_identity().credential.as_basic()
            .map(|c| c.identifier == peer_id_bytes).unwrap_or(false))
        .map(|m| m.index())
        .ok_or(MlsError::UnknownMember)?;
    let commit = group.commit_builder().remove_member(leaf_index).map_err(MlsError::from)?.build().map_err(MlsError::from)?;
    group.apply_pending_commit().map_err(MlsError::from)?;
    let commit_bytes = commit.commit_message.to_bytes()
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })?;
    let new_epoch = group.current_epoch();
    group.write_to_storage().map_err(MlsError::from)?;
    let new_group_state = extract_state(&gs, &group_id)?;
    Ok(CommitOutput { commit_bytes, welcome_bytes: None, new_group_state, new_epoch })
}

// ─────────────────────────────────────────────────────────────────── Helpers

fn peer_id_from_key_package(kp_msg: &MlsMessage) -> Result<String, MlsError> {
    let kp = kp_msg.as_key_package()
        .ok_or_else(|| MlsError::Serialization { msg: "not a key package".to_string() })?;
    let basic = kp.signing_identity().credential.as_basic()
        .ok_or_else(|| MlsError::Serialization { msg: "key package has no BasicCredential".to_string() })?;
    String::from_utf8(basic.identifier.clone())
        .map_err(|e| MlsError::Serialization { msg: e.to_string() })
}

fn seed_storage(
    storage: &mut InMemoryGroupStateStorage,
    group_id: &[u8],
    state_bytes: Vec<u8>,
) -> Result<(), MlsError> {
    let gs = GroupState { id: group_id.to_vec(), data: state_bytes.into() };
    storage.write(gs, vec![], vec![])
        .map_err(|e| MlsError::Serialization { msg: format!("{e}") })
}

fn extract_state(
    storage: &InMemoryGroupStateStorage,
    group_id: &[u8],
) -> Result<Vec<u8>, MlsError> {
    storage.state(group_id)
        .map_err(|e| MlsError::Serialization { msg: format!("{e}") })?
        .map(|z| z.to_vec())
        .ok_or(MlsError::InvalidState { msg: "group state missing after write".to_string() })
}

fn roster_peer_ids<C: mls_rs::client_builder::MlsConfig>(group: &mls_rs::Group<C>) -> HashSet<String> {
    group.roster().members_iter()
        .filter_map(|m| {
            m.signing_identity().credential.as_basic().and_then(|c| {
                String::from_utf8(c.identifier.clone()).ok()
            })
        })
        .collect()
}

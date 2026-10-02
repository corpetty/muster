//! Ground-truth vectors for muster's LEZ v0.3.0 public-transaction encoder, produced by
//! LEZ's own types (lee / lee_core / common @ v0.3.0). Signatures use BIP-340 with 32 zero
//! bytes of aux randomness, so they are deterministic.

use base64::{Engine as _, engine::general_purpose::STANDARD};
use common::transaction::LeeTransaction;
use k256::schnorr::SigningKey;
use lee::{
    AccountId, FeeDeclaration, PrivateKey, PublicKey, PublicTransaction, Signature,
    is_fee_authorized,
    public_transaction::{Message, WitnessSet},
};
use lee_core::{
    account::{Nonce, ProgramShardSelector},
    native_token::{Instruction as NativeInstruction, NATIVE_TOKEN_PROGRAM_ID},
};
use serde_json::{Value, json};

/// The LEZ wallet's defaults (lez/wallet/src/lib.rs @ v0.3.0): DEFAULT_GAS_LIMIT and
/// max_fee_for = (gas_limit + ASSUMED_DATA_BYTES 100_000) * ASSUMED_BASE_FEE 64.
const GAS_LIMIT: u64 = 2_000_000;
const MAX_FEE: u128 = (GAS_LIMIT as u128 + 100_000) * 64;

fn secret(b: u8) -> [u8; 32] {
    let mut s = [b; 32];
    s[0] = 0x01; // keep it well below the group order
    s
}

fn key(b: u8) -> (PrivateKey, PublicKey, AccountId) {
    let sk = PrivateKey::try_new(secret(b)).unwrap();
    let pk = PublicKey::new_from_private_key(&sk);
    let id = AccountId::from(&pk);
    (sk, pk, id)
}

fn sign0(sk: &PrivateKey, msg: &[u8; 32]) -> Signature {
    let signing_key = SigningKey::from_bytes(sk.value()).unwrap();
    let sig = signing_key.sign_prehash_with_aux_rand(msg, &[0u8; 32]).unwrap();
    Signature { value: sig.to_bytes() }
}

fn tx_vector(name: &str, program: AccountId, selectors: Vec<ProgramShardSelector>,
             signers: &[&PrivateKey], nonces: Vec<u128>, instruction: Vec<u8>,
             fee: Option<FeeDeclaration>) -> Value {
    let msg = Message::new_preserialized(program, selectors.clone(),
                                         nonces.iter().map(|n| Nonce(*n)).collect(), instruction.clone(), fee);
    let msg_bytes = borsh::to_vec(&msg).unwrap();
    let msg_hash = msg.hash();
    let raw: Vec<(Signature, PublicKey)> = signers.iter()
        .map(|sk| (sign0(sk, &msg_hash), PublicKey::new_from_private_key(sk))).collect();
    let sigs: Vec<String> = raw.iter().map(|(s, _)| hex::encode(s.value)).collect();
    let tx = PublicTransaction::new(msg, WitnessSet::from_raw_parts(raw));
    assert!(tx.witness_set().is_valid_for(tx.message()), "witness must verify");
    assert!(is_fee_authorized(tx.message(), tx.witness_set()), "the payer must have signed");
    let tx_bytes = borsh::to_vec(&tx).unwrap();
    let tx_hash = tx.hash();
    let lee = LeeTransaction::Public(tx);
    let lee_bytes = borsh::to_vec(&lee).unwrap();
    json!({
        "name": name,
        "program_account": hex::encode(program.value()),
        "selectors": selectors.iter().map(|s| json!({
            "account": hex::encode(s.account_id.value()),
            "program": hex::encode(s.program_account_id.value()),
        })).collect::<Vec<_>>(),
        "nonces": nonces.iter().map(|n| n.to_string()).collect::<Vec<_>>(),
        "instruction": hex::encode(&instruction),
        "fee": fee.map(|f| json!({
            "payer": hex::encode(f.payer.value()),
            "gas_limit": f.gas_limit.to_string(),
            "tip": f.tip.to_string(),
            "max_fee": f.max_fee.to_string(),
        })),
        "message_borsh": hex::encode(&msg_bytes),
        "message_hash": hex::encode(msg_hash),
        "signatures": sigs,
        "tx_borsh": hex::encode(&tx_bytes),
        "tx_hash": hex::encode(tx_hash),
        "lee_tx_base64": STANDARD.encode(&lee_bytes),
        "lee_tx_hash": lee.hash().to_string(),
    })
}

fn main() {
    let keys: Vec<(u8, (PrivateKey, PublicKey, AccountId))> =
        [0x11u8, 0x22, 0x33].iter().map(|b| (*b, key(*b))).collect();
    let key_vectors: Vec<Value> = keys.iter().map(|(b, (_, pk, id))| json!({
        "secret": hex::encode(secret(*b)), "xonly": hex::encode(pk.value()), "account_id": hex::encode(id.value())
    })).collect();
    let (ka, _, a) = &keys[0].1;
    let (_, _, b) = &keys[1].1;
    let (kc, _, c) = &keys[2].1;

    let transfer = |amount: u128| borsh::to_vec(&NativeInstruction::Transfer { amount }).unwrap();
    let native = |id: &AccountId| ProgramShardSelector::native_balance(*id);

    let txs = vec![
        // the sender pays its own fee
        tx_vector("native-transfer-self-pay", NATIVE_TOKEN_PROGRAM_ID, vec![native(a), native(b)],
                  &[ka], vec![0], transfer(1000),
                  Some(FeeDeclaration::new(*a, GAS_LIMIT, 0, MAX_FEE))),
        // a later nonce and a large amount: u128 little-endian throughout
        tx_vector("native-transfer-nonce-7", NATIVE_TOKEN_PROGRAM_ID, vec![native(a), native(b)],
                  &[ka], vec![7], transfer(340_282_366_920_938_463_463_374_607_431_768_211_455),
                  Some(FeeDeclaration::new(*a, GAS_LIMIT, 0, MAX_FEE))),
        // another account pays: it co-signs, and its nonce follows the others
        tx_vector("native-transfer-co-signing-payer", NATIVE_TOKEN_PROGRAM_ID, vec![native(a), native(b)],
                  &[ka, kc], vec![5, 9], transfer(1),
                  Some(FeeDeclaration::new(*c, GAS_LIMIT, 3, MAX_FEE))),
        // a fee-exempt message (system transactions only): the None tag
        tx_vector("native-transfer-fee-exempt", NATIVE_TOKEN_PROGRAM_ID, vec![native(a), native(b)],
                  &[ka], vec![0], transfer(1000), None),
    ];

    let out = json!({
        "lez": "v0.3.0",
        "native_token_program": hex::encode(NATIVE_TOKEN_PROGRAM_ID.value()),
        "default_gas_limit": GAS_LIMIT.to_string(),
        "default_max_fee": MAX_FEE.to_string(),
        "keys": key_vectors,
        "txs": txs,
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

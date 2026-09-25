//! Ground-truth vectors for muster's LEZ v0.2.4 public-transaction encoder, produced by
//! LEZ's own types (lee / lee_core / common @ v0.2.4) and lez-multisig's multisig_core.
//! Signatures use BIP-340 with 32 zero bytes of aux randomness, so they are deterministic.

use base64::{Engine as _, engine::general_purpose::STANDARD};
use common::transaction::LeeTransaction;
use k256::schnorr::SigningKey;
use lee::{
    AccountId, PrivateKey, ProgramDeploymentTransaction, PublicKey, PublicTransaction, Signature,
    program::Program,
    public_transaction::{Message, WitnessSet},
};
use lee_core::account::Nonce;
use multisig_core::Instruction;
use serde_json::{Value, json};
use token_core::Instruction as TokenInstruction;

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

fn words_le(words: &[u32]) -> String {
    hex::encode(words.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<u8>>())
}

fn sign0(sk: &PrivateKey, msg: &[u8; 32]) -> Signature {
    let signing_key = SigningKey::from_bytes(sk.value()).unwrap();
    let sig = signing_key.sign_prehash_with_aux_rand(msg, &[0u8; 32]).unwrap();
    Signature { value: sig.to_bytes() }
}

fn tx_vector(name: &str, program: [u32; 8], accounts: Vec<AccountId>, signers: &[&PrivateKey],
             nonces: Vec<u128>, instruction: Instruction) -> Value {
    let words = Program::serialize_instruction(instruction).unwrap();
    let msg = Message::new_preserialized(program, accounts.clone(), nonces.iter().map(|n| Nonce(*n)).collect(), words.clone());
    let msg_bytes = borsh::to_vec(&msg).unwrap();
    let msg_hash = msg.hash();
    let raw: Vec<(Signature, PublicKey)> = signers.iter()
        .map(|sk| (sign0(sk, &msg_hash), PublicKey::new_from_private_key(sk))).collect();
    let sigs: Vec<String> = raw.iter().map(|(s, _)| hex::encode(s.value)).collect();
    let tx = PublicTransaction::new(msg, WitnessSet::from_raw_parts(raw));
    assert!(tx.witness_set().is_valid_for(tx.message()), "witness must verify");
    let tx_bytes = tx.to_bytes();
    let tx_hash = tx.hash();
    let lee = LeeTransaction::Public(tx);
    let lee_bytes = borsh::to_vec(&lee).unwrap();
    json!({
        "name": name,
        "program": words_le(&program),
        "accounts": accounts.iter().map(|a| hex::encode(a.value())).collect::<Vec<_>>(),
        "nonces": nonces.iter().map(|n| n.to_string()).collect::<Vec<_>>(),
        "instruction_words": words,
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
    let keys: Vec<(u8, (PrivateKey, PublicKey, AccountId))> = [0x11u8, 0x22, 0x33, 0x44].iter().map(|b| (*b, key(*b))).collect();
    let key_vectors: Vec<Value> = keys.iter().map(|(b, (_, pk, id))| json!({
        "secret": hex::encode(secret(*b)), "xonly": hex::encode(pk.value()), "account_id": hex::encode(id.value())
    })).collect();
    let (k1, _, m1) = &keys[0].1;
    let (_, _, m2) = &keys[1].1;
    let (_, _, m3) = &keys[2].1;
    let (_, _, m4) = &keys[3].1;

    // the deployed program and the token program, as their [u32; 8] image ids
    let image = |hexs: &str| -> [u32; 8] {
        let b = hex::decode(hexs).unwrap();
        let mut w = [0u32; 8];
        for i in 0..8 { w[i] = u32::from_le_bytes(b[4*i..4*i+4].try_into().unwrap()); }
        w
    };
    let multisig = image("2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7");
    let token = image("ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b");

    let ck = [7u8; 32];
    let state = AccountId::new([0xa1; 32]);
    let prop = AccountId::new([0xa2; 32]);
    let vault = AccountId::new([0xa3; 32]);
    let to = AccountId::new([0xa4; 32]);
    let seed = [0x5eu8; 32];
    let transfer = Program::serialize_instruction(TokenInstruction::Transfer { amount_to_transfer: 200 }).unwrap();

    let instructions = vec![
        ("create", Instruction::CreateMultisig { create_key: ck, threshold: 2, members: vec![*m1.value(), *m2.value(), *m3.value()] }),
        ("propose", Instruction::Propose {
            target_program_id: token, target_instruction_data: transfer.clone(), target_account_count: 2,
            target_account_ids: vec![*vault.value(), *to.value()], pda_seeds: vec![seed], authorized_indices: vec![0],
            create_key: ck, proposal_index: 2 }),
        ("approve", Instruction::Approve { proposal_index: 2, create_key: ck }),
        ("reject", Instruction::Reject { proposal_index: 3, create_key: ck }),
        ("execute", Instruction::Execute { proposal_index: 2, create_key: ck }),
        ("propose-add-member", Instruction::ProposeAddMember { new_member: *m4.value(), create_key: ck, proposal_index: 4 }),
        ("propose-remove-member", Instruction::ProposeRemoveMember { member: *m3.value(), create_key: ck, proposal_index: 5 }),
        ("propose-change-threshold", Instruction::ProposeChangeThreshold { new_threshold: 3, create_key: ck, proposal_index: 6 }),
    ];
    let instr_vectors: Vec<Value> = instructions.iter().map(|(n, i)| json!({
        "name": n, "words": Program::serialize_instruction(i.clone()).unwrap()
    })).collect();

    let txs = vec![
        tx_vector("create", multisig, vec![state, *m1, *m2, *m3], &[], vec![],
                  instructions[0].1.clone()),
        tx_vector("approve", multisig, vec![state, *m1, prop], &[k1], vec![5],
                  instructions[2].1.clone()),
        tx_vector("execute", multisig, vec![state, *m1, prop, vault, to], &[k1], vec![u128::from(u64::MAX) + 9],
                  instructions[4].1.clone()),
    ];

    let bytecode = vec![0xde, 0xad, 0xbe, 0xef, 0x01];
    let deploy = ProgramDeploymentTransaction::new(lee::program_deployment_transaction::Message::new(bytecode.clone()));
    let deploy_lee = LeeTransaction::ProgramDeployment(deploy);
    let deploy_bytes = borsh::to_vec(&deploy_lee).unwrap();

    let out = json!({
        "source": "logos-execution-zone v0.2.4 (lee, lee_core, common) + lez-multisig multisig_core (feat/lee-v0.2.4)",
        "token_transfer_200_words": transfer,
        "token": {
            "new_fungible_definition_muster_test_1000000": Program::serialize_instruction(TokenInstruction::NewFungibleDefinition { name: "MusterTest".to_string(), total_supply: 1_000_000 }).unwrap(),
            "initialize_account": Program::serialize_instruction(TokenInstruction::InitializeAccount).unwrap(),
            "transfer_500": Program::serialize_instruction(TokenInstruction::Transfer { amount_to_transfer: 500 }).unwrap(),
            "transfer_200": transfer,
        },
        "keys": key_vectors,
        "instructions": instr_vectors,
        "txs": txs,
        "deploy": {"bytecode": hex::encode(&bytecode), "lee_tx_base64": STANDARD.encode(&deploy_bytes),
                   "lee_tx_hash": deploy_lee.hash().to_string()},
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

//! Ground truth for Muster's Nim reading of a LEZ v0.4 private payee (exo-ea3,
//! `module/src/lez/msig.nim` `decodeRecipient` / `recipientAddress`): a `lee_core::Recipient` as
//! borsh, and the address a payment to it names, from LEZ's own crates. Two recipients from fixed
//! keys: a plain one, and one blinded by an opening.
//!   cargo run -p msig_host04 --bin msig_recipient_vectors04 > ../../../module/tests/vectors/lez-msig/v04-recipients.json

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::Recipient;
use lee_core::PrivateAccountKind;

fn main() {
    let keys = GroupKeyHolder::from_gms([0x42; 32]).derive_regular_shared_account_keys(&[0x07; 32]);
    let base = Recipient {
        npk: keys.generate_nullifier_public_key(),
        vpk: keys.generate_viewing_public_key(),
        kind: PrivateAccountKind::Regular,
        opening: None,
    };
    let blinded = Recipient { opening: Some([0x5b; 32]), ..base.clone() };
    let row = |r: &Recipient| {
        format!(
            "    {{\"recipient\": \"{}\", \"accountId\": \"{}\", \"address\": \"{}\"}}",
            hex::encode(borsh::to_vec(r).unwrap()),
            hex::encode(r.account_id().as_ref() as &[u8]),
            hex::encode(r.address().as_ref() as &[u8])
        )
    };
    println!(
        "{{\n  \"source\": \"programs/lez-msig/lez04/host/src/bin/msig_recipient_vectors04.rs on LEZ v0.4.0-rc3\",\n  \"recipients\": [\n{},\n{}\n  ]\n}}",
        row(&base),
        row(&blinded)
    );
}

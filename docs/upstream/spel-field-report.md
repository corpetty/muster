# Field report: lez-msig's IDL through SPEL

**To:** the SPEL maintainers (`logos-co/spel`).
**From:** the Muster team (`corpetty/muster`), building RFP-005's multisig, `lez-msig`.
**Date:** 2026-11-27. **Status:** notes and asks, kept current as we go.

## One line

SPEL's `refactor/lez-v0.4.x` branch (pinned `0d42ddb9`) generates an IDL v2 for lez-msig's
instruction and state, with the types named in `spel.toml` and no annotations in our code. It
describes every type we use. Three things get in the way: the message the program actually
decodes cannot be described; state types outside the crate cannot be reached; and **`spel encode`
silently drops the elements of a vector after the first**.

## What we ran

- **The IDL:** `programs/lez-msig/lez04/spel.toml` names `message = "Instruction"` and
  `state = "State"` in our rules crate. `spel generate-idl` writes
  `programs/lez-msig/lez04/idl/lez_msig.json`.
- **The checks:**
  - `programs/lez-msig/lez04/tools/idl.sh --check` regenerates the IDL and compares it with the
    committed one.
  - It also decodes one of Muster's own `State` test vectors through the IDL with `spel inspect`,
    and refuses on a single byte of difference.
  - CI runs both (Muster PR #405).
- **The tools:** the `spel` CLI built from the same commit.

## What worked as designed

- **Naming types in `spel.toml`** kept our rules crate free of any SPEL dependency, which matters
  to us: that crate must depend on nothing from LEZ. Thank you for offering that route as well as
  `#[state]`.
- **Every type we use is described:** enums with struct and tuple variants, `u128`, `Option`,
  nested `Vec`s, and fixed arrays behind type aliases (`[u8; 32]`, `[u8; 64]`).
- **`spel inspect` decodes a real `State`** byte for byte.

## What we hit, and what would help

### 1. `spel encode` silently drops vector elements after the first

**[measured]**
- `Action::Cancel(Vec<u64>)` cancels the proposals with the given nonces.
- Asked to encode `{"Cancel":[3,300]}`, `spel encode` returns the same bytes as for
  `{"Cancel":[3]}`.
- The vector's length prefix is `01000000`, and `300` is gone. No error and no warning.

Reproduce it with spel at `0d42ddb9` and the IDL in `programs/lez-msig/lez04/idl/lez_msig.json`:

```
Z='"0000000000000000000000000000000000000000000000000000000000000000"'
P='{"multisig":'$Z',"zone":'$Z',"epoch":0,"nonce":0,"action":{"Cancel":[3,300]},"expires_ms":1,"proposer":'$Z'}'
spel --idl lez_msig.json -- encode ExecuteQueued --proposal "$P" --executor none --at-ms 5
```

The output contains `…03` `01000000` `0300000000000000` `…`: variant 3, a vector of one element,
the element 3. We expected `02000000`, then `3` and `300`.

**Why it matters:**
- A signer shown the JSON would approve "cancel 3 and 300", while the bytes cancel 3 only.
- Signing tools are exactly where "what you see is what you sign" must hold.

**Ask:** encode every element, or refuse the input.

### 2. `spel encode` refuses vectors inside JSON-valued fields

**[measured]** These are refused, even when empty:
- `Config.targets` and `SpendingLimit.signers` (`Vec<[u8; 32]>`);
- `Action::Call`'s `rows` (`Vec<Row>`);
- `Action::Config` (`Vec<ConfigChange>`).

So `spel encode` cannot build most of our messages. An `ExecuteQueued` of a plain transfer
encodes correctly, byte for byte against our vectors.

**Ask:** accept vectors anywhere in a JSON-valued field. It may share a cause with §1.

### 3. The message a program decodes cannot be a struct

**[measured]**
- Our v0.4 guest decodes `ProgramInstruction`, a struct: `create_key ‖ placement ‖ Instruction`.
  The account's placement comes before the instruction, because the program re-derives its own
  account from it.
- `spel generate-idl --message ProgramInstruction` refuses with `ProgramInstruction is not an enum`.
  An IDL v2 message must be an enum whose tag is the first byte.
- So our IDL describes `Instruction`, which starts 33 bytes in on the public posture, and
  `spel send` cannot build a complete lez-msig message.

**Ask:** allow a struct as the message, or a declared prefix before the enum.

### 4. State types are looked up in the crate only

**[measured]**
- `--state` finds types only in the crate it is run on.
- Our `Placement`'s private variant holds LEE's `NullifierPublicKey` and `ViewingPublicKey`, which
  come from a git dependency, not a path dependency. Neither the type nor anything holding it can
  be described.

**Ask:** resolve types through dependencies, or let `spel.toml` name a crate per type.

## Reproduce

- **The IDL and its check:** `programs/lez-msig/lez04/tools/idl.sh --check`. It installs the
  pinned spel into `~/.cache/muster/spel-<rev>`; `SPEL=` points at another build.
- **§1:** the commands above.
- **§2–§4:** the notes in `programs/lez-msig/README.md`, "IDL".

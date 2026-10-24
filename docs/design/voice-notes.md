# Voice notes: a short recorded clip in the room, sealed like text, one fixed size on the wire

Status: **proposed 2026-10-21 by an outside contributor; slices S1–S10 are built on this
branch. Of S11, the checks in Basecamp 0.3.2's own window have run, at `bbae7d8`, before §9's
start thread: `logos_host` survives `voice_record_start`, macOS never asks for the microphone
and denies it, so the capture is zeros and Send refuses it `silent` with the Basecamp 0.3.2
note, and a note crossed from one profile to another, drawn and played (§11, §15, §17).
Nothing has run in Basecamp's window since the start thread. The real-device test has run
on this Mac, outside Basecamp: its microphone leg at `bbae7d8`, before the start thread, its
speaker leg on that thread in S2's review, and both legs again on 2026-10-23 at `08dfcb3`, on
it, with no permission prompt standing (§17 S11). S9's two-runner self-test ran on the fork's
Linux CI at `bbae7d8` and failed there on its own reading of the logs, though B had played
the note; at `08dfcb3`, reading them as it does now, it passed there on both fleets, on the
C++ UI (§15). The module calls the self-test makes have run three times from one headless
host to another on the live fleet, with no UI, the last at `08dfcb3`, where C's start on the
null device went through the start thread in logosctl's `logos_host` (§15).** This document is
the first commit of a draft PR. The wire format (§3–§5) is what S4–S10 are built on, so an
objection to it now means reworking those slices (§18). There is no exo id yet
(§18): the slices are S0–S11 in the order of §17, and the commit scope is `voice-notes` until
an id is assigned. A code path named below as new is **planned** unless its slice is built.
Every file:line reference is to `main` at `67701f8`, except those marked "on this branch".

Where it comes from: the design note *Voice in Muster* (2026-10-21, desk research against
`67701f8`) compared four designs for voice against the invariants. It recommended
asynchronous voice notes over the existing room first, and live calls only through a separate
ADR, labelled content-private, never metadata-private. This is that first part. The note is
not in the repo; everything in it that bears on this design is carried here, in §10 (what
still leaks) and §15 (what is not verified).

The idea in one paragraph: a member records up to 60 s. `muster_module` captures it, encodes it
as constant-bitrate Opus, and holds it as a draft in memory. Nothing is posted until the member
presses Send on a surface that has already said who will see what. Send splits the clip into
exactly two author-signed `voice/…` events, sealed under the epoch key as text is, each padded
to one fixed size. So every note costs the same two frames on the wire, whatever its length.
Members fold the parts into notes, and the thread shows a card. Play decodes in the module and
hands PCM to the speaker. No voice method returns audio, in either direction. Two existing
methods that return raw log content would carry it, and §10 says how each is closed.

## 1. Goal and non-goals

Goal: a member can record a voice note in a room, hear it back, and send it, and every member
can play it. The design promises the following, and §10 names what it does not:
- content confidentiality as text has it: sealed per epoch, readable by members only (F-16);
- authorship: each note is signed by its author, so a forged one drops out of the room's view
  (exo-f76, invariant 9);
- a store node can tell that a note was sent, to which topic and when, but not how long it is
  (FS-9).

Non-goals for v1:
- **Live calls.** Live audio cannot ride the room transport: every send is stored, messages are
  capped at 150 KiB, and receive is not real-time. Calls are a separate ADR (the design note's
  option B: relay-only, content-private).
- **Re-sharing to late joiners.** A member admitted after a note cannot play it (invariant 7),
  and v1 has no way to share it again into the new epoch. FileShare has one (room-swarm.md §5.3).
- **Transcription, speech-to-text, effects.** Audio is never interpreted.
- **Windows.** The pinned builders have no Windows path (`docs/design/platforms.md`, R8).
- **Attaching a note to an intent.** A note signs nothing for a chain (§16).

## 2. Why room events, not FileShare

FileShare (exo-4d0, `room-swarm.md`) carries sealed blobs of any size, and on first sight it
looks like the natural carrier. It is the worse fit here:

| | Room events (chosen) | FileShare blob |
|---|---|---|
| Needs | nothing new: the room's own transport | `storage_module` installed and running, and a seeder online (`storage_readiness`) |
| Offline members | the store keeps the frames, so a member who was away catches up | a member needs a seeder reachable when they fetch |
| New observers | none: room member and store node | the storage DHT (CID and providers) and storage peers (each seeder's IP), room-swarm.md §5.5 |
| Size of a 60 s note | about 126 KB of clip in two 90 KB frames (§5) | built for multi-MB files; Padmé padding unbuilt (room-swarm.md §7 S2) |
| Private fetch | the room path is already the only path | over Mix, about 15 KB/s: about 8 s for a 120 KB note |

A 60 s note at 16 kbps is the same scale as the largest event the tree already sends: a Monero
multisig blob part of `XBlobPart = 90_000` hex characters per event
(`module/src/coordination/xmr_msig_spend.nim:40`). If notes ever outgrow two frames, FileShare
is the path; v1 does not need it.

## 3. Wire format

### 3.1 Codec

libopus 1.5.2 (nixpkgs at the builder's pin `e9f00bd`, BSD-3), with these settings:
- 48 kHz mono, 20 ms frames (960 samples);
- `OPUS_APPLICATION_VOIP`, `OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)`;
- **hard CBR** (`OPUS_SET_VBR(0)`) at 16,000 b/s;
- DTX 0, in-band FEC 0, complexity 5, maximum bandwidth wideband.

Why these settings:
- **CBR.** With CBR the clip's size is a pure function of its duration, so the fixed padded
  size of §4 can be tight. RFC 6562 §5 and RFC 7587 §3.1.2 both prefer CBR under encryption.
  In a throwaway prototype on this builder's toolchain (Apple M5, 2026-10-21, not in the
  repo), every packet came out at exactly 40 B, for a 1 kHz tone, for silence, and for a mix
  of the two. The encoder pads a short packet up to 40 B with `opus_packet_pad` and refuses a
  longer one.
- **DTX and FEC off.** DTX would shrink silent frames. FEC is useless inside a sealed blob,
  which loses no packets.
- **16 kbps** is Opus's recommended floor for wideband speech.
- **Complexity 5** encoded 60 s in about 0.26 s in the prototype, against about 1.0 s at
  complexity 10. That matters because dispatch is synchronous.

The binding is `importc` with no header, in the style of `module/src/crypto/sodium.nim`. The
ctl functions are declared `{.varargs.}`. Every value argument is passed as `cint` (libopus's
`opus_int32`), never a Nim `int`, which is 64-bit: read back by `va_arg` as an `opus_int32`, it
comes out right only by accident of little-endian layout. Every GET argument is a `ptr cint`.
In the prototype, a fixed-arity `opus_encoder_ctl` returned `OPUS_OK` but set the wrong value
on Apple arm64: `SET_BITRATE(16000)` read back as 300000. Apple arm64 passes variadic
arguments on the stack and fixed ones in registers, so a fixed-arity binding goes wrong there.
AAPCS64 Linux and SysV x86_64 pass both the same way, so there the two bindings behave alike.
CBR sizes follow from the bitrate, so that bug would silently break §4. The codec test reads
every setting back (S1).

### 3.2 The clip record

A CDE record built with `module/src/dcbor` (invariant 5), with no Ogg: no CRCs, no random
serial numbers, no libopusenc. A CDE array of `bstr` is length-prefixed framing for free.

```
{ v: 1, codec: "opus", rate: 48000, ch: 1, frame: 960, br: 16000,
  preskip: <encoder lookahead, 312 in the prototype>, samples: <exact count>,
  packets: [ * bstr ] }
```

- **Why `preskip` and `samples` are stored.** They let the decoder trim the lookahead and the
  zero-filled last frame.
- **Decode is defensive.** libopus decodes room-supplied bytes inside the core, so decode
  checks the structure first, without libopus. It refuses:
  - any other `codec`, `rate`, `ch`, `frame` or `br`;
  - a packet of 0 bytes or over 1,275;
  - `samples` over 2,880,000 (60 s);
  - a packet count other than `ceil((samples + preskip) / 960)`;
  - trailing bytes.

  It then requires `opus_packet_get_nb_samples == 960` for every packet before decoding. A
  refusal is an error value, never a raise and never a Defect.
- **Digest.** The clip's digest is a domain-separated hash-input record over its bytes,
  `muster.voice.clip.v1`. There is no ad-hoc concatenation of the kind `newMessageEvent`
  still uses for message ids (`intent_events.nim:598-612`).

### 3.3 The events

A note is exactly two author-signed events, one per half of the record's bytes:

```
key    voice/<nid>/<author>/<i>/2          i ∈ {0, 1}; author = 128 hex (ed25519 ‖ x25519)
value  {"v":1, "ts":<int s>, "durMs":<int>, "digest":"<64 hex>", "part":"<base64>",
        "authorSig":"<128 hex>"}
nid    16 bytes (32 hex) of digest(hashInput("muster.voice.note-id.v1", author, clip digest, ts))
```

- **Integers only.** Every number is an integer: an author-signed value refuses a float
  (`authorship.nim:95`). `durMs` is the record's own duration, `samples / 48`.
- **Base64, not hex.** The value must be JSON text (`log/log.nim:48-58`). At 4/3, base64 fits
  a 60 s half in one frame; hex at 2× would need three parts.
- **The note id is content-addressed** over (author, clip, ts), so every member derives it,
  and nobody can post under another member's note id (§6).
- **The author is in the key.** `authorOf` classifies events on every hosted read. `message/`
  and `file/` parse their value's JSON to find their author (`authorship.nim:100-125`), but
  that would mean parsing an 84 KB value per voice part on every tick. So the branch reads the
  key:

  `if p[0] == "voice": return (true, (if p.len >= 3: p[2] else: ""))`

  A malformed shape is still author-bearing, so it can never verify. The `authorship.nim`
  header table gains the row, and `authorship_test` gains a section §11, appended (invariant
  tests are append-only).
- **No `parents`.** A part is built the way `newMessageEvent` builds a message, with
  `parents` empty; its order rides `after` (`docs/design/causal-parents.md`). §5's worst case
  assumes `"parents":[]`.
- **Publishing.** Each part is published through `publishAuthored(s, ks, e)`, and
  `session.publish` pads every `voice/` key to `VoiceFrameBytes` itself (§4). No call site
  passes the pad, so none can forget it.

### 3.4 Constants

| Name | Value | Why |
|---|---|---|
| `VoiceMaxMs` | 60,000 | the cap the device callback enforces (§9) |
| `VoiceMinMs` | 500 | shorter is refused at Send (`too-short`) |
| `VoiceBitrate` | 16,000 | §3.1 |
| `VoiceParts` | 2 | a fixed part count, so the count says nothing about length |
| `VoiceFrameBytes` | 90,112 (88 KiB) | the padded plaintext of every voice frame (§4, §5) |

Changing any of these after release strands notes already sent: a new value is a `v: 2`.

## 4. Padding: `session.publish(padTo)`, and why the pad goes on the frame

**Today.** `session.publish` ingests the event, encodes it as JSON (`encodeEvent`, not
exported), seals it and sends `@[FrameData] & s.crypto.seal(encodeEvent(e))`
(`coordination/session.nim:168-184`). The seal is libsodium secretbox, which adds a 24-byte
nonce and a 16-byte MAC (`crypto/epoch_crypto.nim:144-147`). Nothing in `module/` pads
anything today.

**Built (S4).** `publish(ev, padTo = 0)`. With `padTo > 0`, the event's JSON is followed by
ASCII spaces up to exactly `padTo` bytes before sealing. `padTo = 0` is today's path, byte for
byte, for every key but one:
- **A `voice/` key is always padded to `VoiceFrameBytes`.** `publish` sets that pad itself
  and raises on any other non-zero `padTo` for such a key.
- **Why the key decides, not the caller.** `publish` already has a second send path for the
  same event: one the log holds is re-sealed as the stored copy (`session.nim:168-184`). A
  retried Send or a re-announce takes it. If the pad were an argument at each call site, a
  path that forgot it would send an unpadded frame that shows the note's length, and nothing
  would fail.

So every voice frame is exactly 1 + 24 + 16 + 90,112 = **90,153 B**, on either path.

**Which copy the held path seals** (built, on this branch). On `main`, the held path re-seals the
copy the log keeps: of the copies of one id, the one with the smallest `afterDigest` (`log.nim`
`keep`). Ingest takes a copy with an `after` of any length, unsigned, from any member, so a
member who received a part could plant a copy whose `after` alone overflows the pad and that
sorts first; every later held-path send of that part would then raise `FrameTooLarge`, and a
retried Send would fail for good. So `publishAuthored` passes `publish` the copy to seal
(`asGiven`): for an event the log already holds, the copy whose `after` this member signed,
the smallest by `afterDigest` if there are several, as the room's view picks; with none, the
event with no ordering claim, which is what the room's view makes of any copy whose `after`
its author did not sign (`authorship.copyToSeal`). That copy's `after` came from `heads()`, at
most 8 ids, so it fits the pad (§5). `voice_live_test` §24 plants such a copy with 1,400 ids
and retries. **This changes every author-signed kind, not voice alone:** a re-announce or a
retried publish of a message, a decline, a share, an account disclosure or any other kind
`publishAuthored` signs now re-seals the author's own `after`-signed copy, where `main`
re-sealed the log's kept copy, which may be another member's (`authorship_test` §12: an
account disclosure re-announced for a later joiner, and every member converges on the
author's order).

Why on the frame, not inside the value:
- `publishAuthored` signs the value first. Only then does it set `after = heads()` (0 to 8 ids,
  `log.nim:226`) and sign `afterSig` (`authorship.nim:279-287`).
- A pad inside the value would be fixed before those bytes exist, so it could not account for
  them.
- The pad sits outside `value`, so the event id does not change: the id hashes parents, key
  and the value's text, never the frame.

Older clients read it unchanged. `decodeEvent` is `parseJson(toStr(b))` (`session.nim:82-83`).
At the builder's Nim pin (2.2.4), the parser accepts trailing whitespace (5,000 spaces were
tried, while planning) and trailing `//` or `/* */` comments, takes a NUL as the end of its
input (accepting anything after one), and refuses other trailing text, such as a letter or a
`}`. The pad is ASCII spaces, so only the first of those matters here. Nothing pads with NULs,
and `session_pad_test` fails a NUL pad (`docs/labbook/voice-notes-audio-stack.md` §8). So:
- no new frame kind;
- no `room_journal` change: journal frames are opaque, with `MaxFrame` 16 MiB
  (`room_journal.nim:24`);
- a peer on a Muster from before voice notes (0.3.2 or earlier) reads a padded frame as an
  ordinary event, and its thread ignores the `voice/` key (§7).

**What does not fit, raises.** An event whose JSON exceeds `padTo` raises `FrameTooLarge`
before anything is ingested, journalled or sent. Send seals both parts before either frame
leaves (§10), so a part that does not fit is refused before any frame of its note is sent; for
a draft under the cap neither can (§5). Today nothing guards size: an oversized frame
lands in the sender's own log and reaches nobody, and a failed send is logged only under
`MUSTER_LP_DEBUG` (`transport/delivery.nim:118-123`).

## 5. Size budget

The record's figures are arithmetic, and S1 holds them: `maxClipBytes` gives 126,119 B at
60 s and 1,166 B at 500 ms (`voice_clip_test`), and a real 60 s encode stays within it
(`voice_codec_test` §5). The JSON around a half is measured: `session_pad_test` puts the
worst case below, a 63,060 B half with 8 heads, at 85,257 B, 4,855 B under the pad, and
`probe_voice_fixed_size_stepper` sends 60 s notes with 8 heads in 90,153 B frames. Both run
over `LocalTransport`, not the fleet (§15). A 60 s note is 2,880,000 samples. The encoder is
flushed through its 312-sample lookahead, so by §3.2's count it is
ceil((2,880,000 + 312) / 960) = 3,001 packets.

| | Bytes |
|---|---|
| One Opus packet at 16 kbps, 20 ms, CBR | 40 |
| The same packet inside the CDE array (`bstr` header) | 42 |
| A 60 s record: 3,001 packets plus 77 B of header | 126,119 |
| The larger half | 63,060 |
| The same half as base64 | 84,080 characters |
| The event JSON, worst case: 128-hex author, `"parents":[]`, 8 heads in `after`, `afterSig` | about 85,257 |
| The padded plaintext, `VoiceFrameBytes` | 90,112 |
| Margin left in the worst case | about 4,855 |
| One frame on the wire: kind 1 + nonce 24 + MAC 16 + 90,112 | 90,153 |
| **One note, any length from 0.5 s to 60 s: 2 frames** | **180,306** |
| Delivery's per-message cap, as the tree assumes it (`xmr_msig_spend.nim:40`) | 153,600 (150 KiB) |

A 500 ms note is 26 packets, a 1,166 B clip, and still costs two full frames. That is the
price of hiding length.

The alternative was 12 kbps in one 128 KiB frame (§18). It would mean narrower speech, and a
single frame bigger than anything the tree sends today.

## 6. The fold

`reduceVoice(roomEvents(s))` (built, S5: `coordination/voice.nim`) is pure and order-free, and
it never links libopus. It imports only the clip record's structural checks. Its rules:

1. **Authentic only.** `roomEvents` has already dropped a part that is forged, unsigned,
   replayed from another room, or edited (`authorship.nim:262-277`).
2. **Shape.** The key is exactly `voice/<nid>/<author>/<i>/<n>`, with `n == 2`, `i` in
   {0, 1}, a 32-hex nid and a 128-hex author, all lowercase. The value holds the fields of
   §3.3 and no others: `v` 1, `ts` an integer, `durMs` an integer in 0..`VoiceMaxMs`,
   `digest` 64 lowercase hex, and `part` in canonical base64, the one spelling `encode` gives
   its bytes. Anything else is dropped without raising.
   - **Base64 is checked before it is decoded.** std/base64's `decode` (Nim 2.2.4,
     `lib/pure/base64.nim:252-262`) skips whitespace inside its 4-character loop and then
     reads past the end of the string. `"    AB"` and `"AAAA     AAA"` each raise an
     IndexDefect, which no `except CatchableError` catches, and any member can sign such a
     part. So the fold first requires a length that is a multiple of 4, the standard
     alphabet, `=` only as final padding and zero spare bits, and only then decodes.
3. **The first copy stands.** In `canonicalOrder`, the first copy of each (nid, author, i)
   stands, and an equivocating later copy is ignored, as in `readBlob`
   (`xmr_msig_spend.nim:60-78`).
4. **No squatting.** `nid` must equal `noteIdOf(author, digest, ts)`, the same refusal
   `fileIdOf` makes for a squatted file id (`swarm.nim:135`).
5. **The parts must agree.** Both carry the same `ts`, `durMs` and `digest`. The reassembled
   record must match that digest and pass the structural checks of §3.2, and `durMs` must be
   its own duration.
6. **States.** A note is one of:
   - `complete`: both parts, every check passed;
   - `arriving`: one part so far;
   - `broken`: the parts disagree, the digest misses, or the structure fails.

   Only a complete note plays.
7. **Epochs.** A part sealed in an epoch this member never held never opens, so the fold never
   sees it (F-16).

The result is `{nid, author, ts, durMs, state, parts}` per note, ordered by (ts, nid), where
`parts` names the standing parts' event ids. The fold runs in two passes:
- **The header pass** reads each part's key and value and checks rules 2 to 4, base64
  spelling included, but decodes nothing. It decides which parts stand and which notes exist.
  `threadLastTs` needs nothing more, because a note's row is there whatever its state.
- **The verdict pass** judges a note of two parts by rules 5 and 6. It decodes the halves,
  then checks their agreement, the digest and the record.

**The memo.** A part's header fields are a pure function of its event id, and a verdict of
the two standing parts' ids, because an id is a content address. So every fold takes an
optional `VoiceMemo` (`reduceVoice`, `threadRows`, `threadLastTs`, `voiceStanding`,
`voiceNoteOf`, `voiceRecordOf`, and the room's other folds that read a part: `reduceFlow`,
`logProvenance` and `reduceRoomGraph`), which holds both:
- **Headers**, by event id: `v`, `ts`, `durMs` and `digest`, and whether the value is a
  part's at all, never the half. A part read once is not parsed again, and a part a pass
  parses keeps its half for that pass alone. A verdict or a decode reads a half back from its
  event: once per pair judged, and once per Play. The headers came with PR 340's review,
  which found the header pass parsing every part's 84 KB value on every poll.
- **Verdicts**, keyed by the two ids, complete and broken alike, so a clip is not decoded and
  checked on every read. A part that comes to stand in another's place, such as an
  equivocating copy that sorts first, makes a new key, so its note is judged afresh.
- **Where it lives.** The hosted layer keeps one per room (S7, built:
  `VoiceRecorder.memoFor`). Every hosted read that folds the room's voice parts goes through
  it, by a recorder proc the hosted method calls:
  - `coordinate_messages`' rows (`rows`), on the room's 1 s tick;
  - the `lastTs` of `coordinate_conversations` for every joined room (`lastTs`, given the
    events the method already read);
  - `coordinate_flow` (`flowRows`), on the room's 5 s tick;
  - `coordinate_graph` (`graphOf`), every 2 s while the room map is open: its provenance,
    its flow, and each part's content, which is read off the part's header
    (`voiceContentOf`);
  - `coordinate_provenance` (`provenanceOf`);
  - `voice_play`, which reads its note from one header pass (`voiceNoteOf`).

  The flow, provenance and the map went through no memo until the second pass of PR 340's
  review, which found the flow and the map polled, not read on demand: each of their polls
  parsed every part's value again, once in the flow and three times in the map.
  `coordinate_proof`, which no UI calls, reads the header pass with no memo, once per call
  and only in a room whose raw log holds a `voice/` key. An entry under `voice/` that holds
  no part's value (a key of no part's shape, a value the fold refuses, an equivocating later
  copy) the map parses on each poll for its content, as it parses each message.
- **Memory.** A part's id and four fields, a few hundred bytes, and a verdict, about 140 B,
  per pair of parts that ever stood, against their 90 KB frames in the log (not measured).
  The log is append-only, so a room's memo is bounded by its log,
  and `coordinate_leave` drops it (`VoiceRecorder.forgetRoom`), so the memos are those of the
  rooms joined, never of every room ever read.

`voice_test` §16 holds every fold output byte-identical with a memo and without one, in any
order, duplicated, and as the set grows; §17 does the same for the flow, provenance and the
map, whose cold memo parses each part once across the three and whose warm one parses none.
`voice_live_test` §27 counts the parses (`voiceParses`, `voiceHalfReads`): over an unchanged
log a second read parses 0 parts, a new part alone is parsed, and Play goes through one pass.
§28 counts them for the recorder procs the flow, the map, provenance and `lastTs` are served
by: none on the next poll, and none at all once the thread's rows have read the room.

Measured on darwin-arm64 (Apple M5, `-d:release`, 20 notes of 60 s and 20 messages, outside
the repo), per call, before the header memo and after it:
- with no memo, about 44 ms, or 2.2 ms a note, either way;
- `threadRows` with a warm memo, about 13 ms before, 3.5 ms after;
- `threadLastTs`, about 13 ms with no memo, 3.5 ms with a warm one;
- Play's lookup, about 26 ms before (two header passes, the second with no memo, and the
  verdict again), 3 ms after (one pass, and the two halves read back).

What a warm memo still pays is the pass itself, and that grows with the bytes of the room's
voice history, not with its parses: each voice event's id, whose memo key copies the whole
value and hashes it (`log.nim:71-76`), the authentic view's checks and copies, the
canonical order, and the copies a pass makes. Measured in the final check of PR 340's review
fixes (darwin-arm64, Apple M5, `run-suite.sh`'s `-d:release` flags, 20 notes of 60 s and 20
messages over `LocalTransport`, read as the second member, a bench outside the repo), per
call with a warm memo:
- `eventId` of one part (84,346 B of value) from its memo, about 23 µs (a message's, 1.3 µs;
  the digest itself, uncached, about 470 µs), so about 0.9 ms for the room's 40 parts, in
  each pass that names them;
- `roomEvents`, the authentic view, its caches warm: about 3.0 ms;
- `coordinate_messages`' rows (`rows`: `roomEvents`, then `threadRows`): about 6.4 ms, each
  second; `threadRows` alone about 3.3 ms;
- `coordinate_conversations`' `lastTs` for the room (`roomEvents`, then `threadLastTs`):
  about 6.4 ms, every 2 s (Main's timer), for each joined room, before that method's other
  folds, which were not timed;
- `coordinate_flow` (`flowRows`, over the view the method has read): about 7.6 ms, and that
  `roomEvents` besides, every 5 s;
- `coordinate_graph` (`graphOf`, over the view the method has read): about 27 ms, and that
  `roomEvents` besides, every 2 s while the map is open.

The same room with notes of 1 s (1,745 B parts) gives 0.4 ms, 0.4 ms, 0.5 ms and 1.9 ms for
the last four, so the cost is the values' bytes. On the module thread, a room of 20 full
notes therefore costs about 12 ms of each second with the room map closed and about 27 ms
with it open, plus the other joined rooms' `lastTs`. It should grow with the bytes its
notes hold, so with each full note, but only one room size was timed, at two note lengths.
Carrying each event's id with it from ingest, one digest per event ever, would take the
values' bytes out of every pass; that changes the kind-agnostic log's `Event`, so it is not
in this PR (§15, "The cost of the fold").

S7 measured the hosted reads the same way, before the header memo (20 notes of 60 s, a
member's session over `LocalTransport`, `-d:release`, darwin-arm64, outside the repo), per
call:
- `roomEvents`, the authentic view: about 37 ms the first time, while it checks and caches
  every part's signature, then about 3 ms;
- the thread's rows as `coordinate_messages` reads them (`roomEvents`, then `threadRows` with
  the room's memo): about 48 ms with a cold memo, then about 16 ms;
- `threadLastTs(roomEvents)`, the `lastTs` of `coordinate_conversations`: about 16 ms;
- `threadRows` with no memo: about 48 ms on every call, which the memo saves.

## 7. Thread rows

The thread is `coordinate_messages`, which returns every message body on each 1 s poll
(`muster_module.nim:4566-4578`). Audio must never ride that. So a note is never a `message/`
event, and there is no pointer message as `intent-ref` uses.

Instead, `threadRows(events)` (built, S5) merges `reduceMessages(events)` with one synthesized
row per note, ordered by (ts, id). The row carries the note in a field of its own, `voice`,
never in `body`. That field is metadata only, under 300 B:

```
{ "id": "<nid>", "author": "<reduceVoice's author>", "ts": N, "body": "",
  "voice": { "v": 1, "note": "<nid>", "durationMs": N, "state": "complete|arriving|broken" } }
```

The hosted layer adds `alias` and `self` to it, as to every row (`voice_live.messagesJson`
on this branch, which `musterCoordinateMessages` calls; `voice_live_test` §22 pins both row
shapes).

**Only `threadRows` can make a voice row, and `voice-note` is a reserved kind.** Without
that, a member could forge a note row:
- Any member, or any co-resident module, can post a `message/` whose body is a typed card as
  JSON `{kind, ...}` (`muster.lidl:119`).
- `reduceMessages` passes bodies through unchanged (`intent_events.nim:614-629`).
- RoomThread makes a card of any body that parses to an object with a `kind`
  (`RoomThread.qml:71-79`).

So a body `{"kind":"voice-note","note":"<Alice's nid>",…}` would draw as a voice-note card
under the forger's name, and its Play would play Alice's audio. That attributes one member's
voice to another, against invariant 9. Three rules close it:
- **The fold alone sets `voice`.** `reduceMessages` builds a row from a message's `author`,
  `ts` and `body` only. `musterCoordinateMessages` serializes just those fields
  (`muster_module.nim:4575-4577`). So no `message/` event can put a `voice` field on a row.
- **The card draws from `modelData.voice` alone.** RoomThread's `parsedCard` refuses
  `voice-note` from a body, so a `message/` that claims it falls through to plain text: the
  forger's raw JSON, under the forger's name, with no voice card and no Play for the note it
  names (the gallery fixture `room-voice-forged` checks each).
- **The card names the fold's author.** The row's `author` is `reduceVoice`'s: the key author
  that `roomEvents` verified (§3.3, §6 rule 1), never anything a message says.

`voice_play` takes the nid alone and checks no author. The only rows that carry a nid in
`voice` are made from the fold, so the name on the card is the note's author by
construction. A co-resident module can call `voice_play` with any nid, but that draws no card
and names nobody (§13).

`threadRows` is used in exactly two places:
- `musterCoordinateMessages`, in place of `reduceMessages` (`:4574`);
- the `lastTs` of `coordinate_conversations` (`:4624-4625`), so a note moves its room up the
  list. That one reads `threadLastTs`, the newest row's ts from the fold's header pass (§6),
  which judges no clip.

`reduceMessages` itself is unchanged. Three things read address shares from it:
- `settle_up.nim:81`;
- `send.nim:28`;
- the shared-address readers in `intent_events.nim` (`:643`, `:664`).

What this means for each kind of reader:
- **The thread.** RoomThread gains a delegate branch that draws a new `CardVoiceNote.qml`
  from `modelData.voice`, beside the `MusterCard { card: msg.parsedCard }` branch
  (`RoomThread.qml:692-695`). `MusterCard.known` (`MusterCard.qml:712`) does not gain
  `voice-note`, because no body may carry it. `CardVoiceNote.qml` is pure render: it emits
  `play` and `stop`, and RoomThread owns the backend calls, as for every card.
- **A peer from before voice notes** (0.3.2 or earlier) shows nothing for a note in its
  thread: it never synthesizes the row, and `reduceMessages` skips the `voice/` events. That
  is better than its unknown-card render: an
  unknown kind draws nothing, or a stray heading, never a text fallback
  (`RoomThread.qml:693, :722`). Its information-flow view and room map do show each part, as
  an unknown `voice` entry: envelope rows only (`flow.nim:121-124` on `main`), and an entry
  node of kind `voice` with basis `sealed` (`room_graph.nim:299-331` on `main`). That entry's
  `content` is the whole value, `part` included (`room_graph.nim:198`, `:348` on `main`), so
  that peer's `coordinate_graph` returns the audio, as its `coordinate_proof` does: §10 lists
  it among what still leaks.
- **Older clients in general.** S8 fixes that fallback for the next unknown kind (built: a
  body whose kind MusterCard does not know is the message's text, RoomThread's `isText`), but
  clients already released keep it.
- **A UI from before S8.** `coordinate_messages` returns a note's row, with an empty `body`.
  RoomThread before S8 parses the body as a card in a `try`, gets null from `""`, and falls
  through to plain chat text (`RoomThread.qml:75-79` on `main`), and the Nim UI passes the
  same JSON through (`ui-nim/app/backend.nim:129` on `main`). So such a UI, paired with this
  module, draws a voice note as an empty chat line under its author's name (§15). S8's
  RoomThread draws the row's `voice` field as a `CardVoiceNote` instead (built).

## 8. Record → draft → send

```
        voice_record_start           the device runs           voice_record_stop, or the 60 s cap
   idle ──────────────────▶ starting ────────────────▶ recording ─────────────────────────▶ draft
    ▲ ▲                        │                                                            │   │
    │ └────────────────────────┘ Stop (not-started), Discard, close: the start let go;      │   │
    │                            a start that fails, or still pending after 15 s: error     │   │
    │              voice_draft_send: two frames published                                   │   │
    ├───────────────────────────────────────────────────────────────────────────────────────┘   │
    └─────────────────────────────────────── voice_draft_discard ───────────────────────────────┘

   voice_play(note | "draft"), from idle or draft → playing (starting until its device runs)
                                       → (end, or voice_play_stop) → back where it was
```

**A device starts off the module thread** (PR 340's review; §9). `voice_record_start` and
`voice_play` answer at once: the device's start runs on a thread of its own, and `voice_status`
says where it stands. A recording is `starting` until the device runs, then `recording`; its
elapsed time and its 60 s cap count from the device's start, since only the device side fills
the buffer. A note playing carries `starting: true` until its device runs, at position 0. While
a start is on its way, `ready.capture` (or `ready.playback`) says `unknown`: nothing is known
yet of the device it starts, and the word an earlier start left (`ok`, or a failure's) would
not be true of this one (`voice_live_test` §29d). The pump then sets `ok` when the device runs.
A start that fails ends the recording, or the playback, with the device's word (`no-device`,
`device-format`), which `ready.capture` or `ready.playback` then says, and `recording.error`
for a recording; one still pending 15 s after the call ends it the same way with
`device-start-slow` (`StartBoundMs`: a working device starts in well under a second, the one
slow start seen is Core Audio waiting on a microphone prompt, §11, and 15 s leaves a person
time to read and answer one while "Starting the microphone…" does not stand longer than anyone
would wait on it). Stop, Discard and close while a start is pending never wait on it: they let
it go, and its thread closes whatever it opens if its start ever returns (§9).

On macOS, in a person's Basecamp 0.3.2, no prompt is asked at all: its `logos_host` lacks the
microphone entitlement, so tccd's policy disallows the prompt and the capture gets zeros (§11),
and the start does not wait. The prompt that held a start was seen only where the app macOS
holds responsible can prompt: a test run from a shell (§17 S11). So the start thread and the
15 s bound guard such hosts, a shell or terminal launch, and a future Basecamp that carries the
entitlement and a usage string, not Basecamp 0.3.2 as it ships.

**The draft.** It lives in module memory only: never on disk, never over IPC. A crash loses
it. There is one draft at a time. Nothing is posted without Send. The draft surface shows Play,
Send, Discard and the disclosure lines first (material-and-disclosure.md §4, rule 2: "Nothing
is disclosed without an act"). Proposed wording, for S8:

> Everyone in this room can play it. Your voice can identify you, here and outside this room.
> The store node sees two sealed frames of one fixed size, and when.

**The methods** (built: in `muster.lidl` since S3 and S7). Each one returns at once. Parameter
names avoid C++ keywords (`7480de8` renamed `private` for that reason), and every method
declares a return type.

| Method | Returns |
|---|---|
| `voice_status()` | the JSON below; it also drives the voice pump |
| `voice_record_start()` | `{ok}` at once, the device's start on its way (above), or `{error}`: `not-joined` · `busy` (starting, recording, playing, or a draft held) · `codec` · `no-device`, or another word the device seam gives at once (`FileAudioIo`'s `no-source`, `device-start-slow` while four earlier starts have not returned, …), which `ready.capture` then says |
| `voice_record_stop()` | `{draft: {durationMs, silent, peak}}` (a draft the 60 s cap already made included), or `{error}`: `not-recording` · `not-started` (the device had not started, so nothing was recorded; its start is let go) · the word of a start that failed or passed 15 s · why the encoder refused |
| `voice_draft_send()` | `{note}`, or `{error}`: `no-draft` · `too-short` · `silent` (with `detail`, the platform note of §11) · `not-joined` · `room-changed` (the joined room is not the one the draft was recorded in) · `too-large`. The draft is kept on every refusal |
| `voice_draft_discard()` | `"ok"`; it also drops a recording in progress or starting |
| `voice_play(note_id)` | `"draft"` or a note id; `{ok}` at once, the device's start on its way, or `{error}`: `unknown-note` · `incomplete` · `broken` (the fold's verdict, or a clip libopus refuses) · `busy` · `no-draft` · `not-joined` (a note with no room) · `codec`, or the device seam's word at once, which `ready.playback` then says. A start that fails or passes 15 s ends the playback, `playing` null and `ready.playback` its word |
| `voice_play_stop()` | `"ok"` |

`voice_status` returns integers, strings, booleans and null, never a float, and never audio:

```
{ ready:     { capture: "unknown|ok|no-device|…", playback: "…", codec: "<opus_get_version_string()>",
               note: "<a platform note, e.g. §11's, or empty>" },
  recording: { state: "idle|starting|recording|draft", elapsedMs, capMs: 60000, peak, capped, silent, error },
  playing:   { note, positionMs, durationMs, starting } | null }
```

**Refusals at Send**, in this order:
- **Too short.** Under 500 ms is refused as `too-short`. That includes a recording of no
  samples at all (Start, then Stop at once), which is too short, not silent, and raises no
  microphone note (`voice_live_test` §16).
- **Silent.** A draft long enough to send whose samples are all exactly zero is refused as
  `silent`, and the platform note says why (§11): it is the refusal's `detail`, and
  `ready.note` once such a recording came back. A low but non-zero peak is only a warning.
- **Another room.** A draft belongs to the room it was recorded in: `voice_record_start`
  takes the room's topic, and a Send while another room is joined is refused as
  `room-changed`, with nothing published to either room (`voice_live_test` §18). So a draft
  is never posted to a room other than the one its draft surface named, and a retry never
  sends a note's second part to another room than its first. `voice_status` does not say
  which room holds the draft yet, so S8's draft surface shows a draft in whichever room is
  open and says whose it is only when Send is refused (§18).
- **A retried Send sends the same note, where the failure is seen.** The note's ts is fixed at
  the draft's first Send. Send signs both parts and puts each into the log and the journal
  before either frame reaches the transport (`session.publishTogether`, §10), so after a
  transport raised between the two frames, the log holds both, and a retry re-sends both on
  the held path (§4), under the same note id, each as this member first sealed it, so a copy
  another member planted cannot block it (`voice_live_test` §15 makes the transport raise
  through a `LocalTransport` subscriber, §24 adds such a copy). Until the retry, the sender's
  own thread shows the note complete while the room may hold only its first part.
  `too-large` is refused before any frame leaves, and cannot happen for a draft under the
  cap (§4, §5).
- **The live transport raises nothing.** `DeliveryTransport.publish` is fire-and-forget: it
  hands the frame to `lp_invoke_async` and returns, and a failed send is logged only under
  `MUSTER_LP_DEBUG` (`delivery.nim:118-123`, `:202-212`). So if either 90 KB frame fails on
  the fleet, Send still returns `{note}` and drops the draft, and every other member can hold
  the note `arriving` for good: nothing re-sends it (`coordinate_reannounce` re-publishes
  intents only). §15 and §18 carry it.

**Built (S7).** `coordination/voice_live.nim`'s `VoiceRecorder` runs the state machine above
for the seven methods. Start, Stop, Send and Play each run the voice pump first, so each
decides on what the device side has done by now: a playback heard to its end is not `busy`,
and a recording the cap ended is a draft Send can send, whether or not anything read
`voice_status` since (`voice_live_test` §17). `voice_status`'s `peak` is the largest |sample| captured since the
last read, and reading it resets it, raw (its coarsening is still open, §13). `elapsedMs` is
what the device side has captured, at 48 samples a millisecond. The `starting` state, the
pump that sees a start land, fail or pass 15 s, and Stop, Discard, Play and close around a
start in flight are `voice_live_test` §29–§31, on `SyntheticAudioIo` with a start held by a
`StartGate` until the test releases it.

**Polling only.** The `.rep` declares no SIGNAL, the module has no clock
(`docs/design/side-modules.md:66`), and the SDK's `emit` callback is a threadvar, so the audio
thread cannot emit. So:
- `voice_status` drives `voicePump`, as `fileshare_files` drives `fileSharePump`
  (`muster_module.nim:2776`);
- `coordinate_intents` also calls it, from its pump list (`:2838-2846`);
- a room's view polls `voice_status` every 250 ms while the microphone starts or records, or
  a note plays (Room's `voicePoll`). A draft only held is not read faster: until PR 340's
  review it kept that poll going for as long as it was held, which can be hours;
- `Main.qml` reads it every second on every page, whether or not a room is open
  (`appVoicePoll`), so a recording any caller started shows (§13): in the strip above every
  page, and in a room's view in the room's own banner too, which is part of its composer. A
  held draft and idle are read at that rate.

Elapsed time on screen comes from a QML clock, started when `voice_status` first says
`recording`. The module's cap is the one that counts. While a recording is `starting`, the
message row's banner says "Starting the microphone…", with Stop and Discard, no time and no
level, and that nothing is recorded until it starts; a note's card says "Starting…" while its
speaker starts. A start that failed or was too slow shows in words (`no-device`: "No microphone
was found on this device."; `device-start-slow`: "The microphone took too long to start. If you
were asked whether to allow it, answer that, then try again."), and so does a Play the module
took whose speaker then did not start. Stop while the microphone is still starting ends the
banner and says "Nothing was recorded: the microphone had not started yet." (the module's
`not-started`, in the table above). The gallery fixture `room-voice-starting` holds each.

**A refusal shows while it holds.** The UI keeps the last voice call's answer with the room the
call was made in and where `voice_status` stood then (the recording's state, the note playing).
Once another room opens, or `voice_status` moves on (the other recording ended, the note
stopped playing), the answer is no longer shown; a refusal such as `busy` or `room-changed`
describes a state that has gone. The gallery fixture `room-voice-refused` holds both. One move
is the call's own: a Stop while the device was starting drops the recording, so `voice_status`
goes from `starting` to idle because of that Stop, and its answer, `not-started`, follows it
there and shows. `room-voice-starting` holds it in both orders, the move before the answer and
the answer before the move (S2's review found the answer was never shown before). Both backends
count their voice answers in `voiceResultSeq`, one more per answer, so an answer identical to
the last one still reads as new: a real backend's second `silent` leaves `voiceResultJson` as
it was. While a call is in flight (the count has not moved since it was made) the last answer
is not shown, since it answered an earlier call. A refusal the person dismissed stays dismissed
until a new answer arrives, and shows again if that answer refuses in the same words (the
notice is keyed by the count); a platform note, once dismissed, stays dismissed until its words
change. `room-voice-refused` holds these too.

## 9. Devices, threads and the build

**The `AudioIo` seam** (built, S2: `module/src/audio/audio_io.nim`). It is built in the shape of
`Transport` and `BlobStore`, and no test mocks it (CLAUDE.md working agreements). Its
implementations:
- `SyntheticAudioIo`: deterministic PCM on a virtual clock, with a collecting sink. It is the
  in-process stand-in, as `LocalBlobStore` is.
- `FileAudioIo`: a 48 kHz mono s16 WAV source (`MUSTER_VOICE_SOURCE`) and a raw PCM sink
  (`MUSTER_VOICE_SINK`), for the offscreen self-test (S9).
- `MiniaudioIo(system | null)`: miniaudio's null backend runs the real device-thread path with
  no device and no permission prompt. The real-device test, `voice_device_e2e` (S11, built),
  sits behind `MUSTER_VOICE_REAL`, in run-suite's E2E list.

**The device callback.** miniaudio calls it on a thread Nim does not own, so it follows the
same rule as `transport/inbound_queue.nim:1-11`:
- no GC allocation, no raise, no Defect (a Defect there takes down `logos_host`);
- `ptr UncheckedArray` and an explicit `min()` everywhere;
- only atomics shared with the module thread.

**Capture.** One buffer, made at record start on C's heap (`calloc`, so any thread can free
it), sized to the cap: 60 × 48,000 samples × 2 B = 5,760,000 B. It is counted by reference:
the recorder holds it, and so does a device start while its start thread runs (below).
- It is **linear and never wraps.** The callback advances an `Atomic[int]` write index, stops
  writing at the cap and sets `capped`. However long the module thread is busy, the buffer
  cannot overflow.
- **Only this thread can enforce the cap.** The module has no clock, and a Stop can queue
  behind a 20 s sync call.
- **The module thread drains it.** The voice pump reads from its own index and Opus-encodes 20
  ms at a time. Stop therefore finds at most about 1 s of audio left to encode. The same pass
  keeps the peak and the all-zero check.

**Playback.** The module thread checks the note (§3.2) and decodes it whole into a shared
buffer; the prototype decoded 60 s in about 27 ms. The callback copies out at an atomic read
index, writes zeros past the end and sets `done`. The pump then releases the device.

**The start thread** (built since PR 340's review: `audio_io.spawnStart`, `MiniaudioIo`'s
start). A device's start is the one device call that can wait on the person: on a Mac, Core
Audio held a capture start while a microphone prompt stood unanswered, in a test run from a
shell (S11, §11); Basecamp 0.3.2's `logos_host` is never prompted, so its start does not wait
(§8). So no start runs on the module thread. `startCapture` and `startPlayback` make the
start's job (the buffer, a reference to it, the context the io holds or a new one, the device's
memory, all on C's heap) and hand it to a detached pthread, then return at once with the stream
`starting`. That thread runs `ma_context_init`, `ma_device_init`, the read-back (S1's rule:
48 kHz mono s16, or `device-format`) and `ma_device_start`, and Nim does not own it, so it keeps
the callback's rule (above): no GC allocation, no raise, no Defect, C's heap and atomics only.
The two threads meet at one atomic by compare-and-swap:
- the start thread, once its start returns: pending → running, or failed with its word;
- the module thread, at Stop, Discard or close before then: pending → let go, and it forgets
  the start at once. The start thread's own swap then fails, so that thread finishes the job:
  it uninitialises the device and context it started, lets go of its buffer reference and
  frees the rest.

**A start let go before its device starts never starts it** (S2's review). The start thread
reads the let-go just before `ma_device_start`: a start given up while its
context and device initialised (or while it waited on the person there) uninitialises them
and starts nothing, so no microphone comes on after the room said the recording ended
(`audio_io_null_test` §7: a test's `StartGate` holds the start after the device's init, and
`devicesStarted` does not move). A start let go in the instant after that read, or while the
start call itself waits, starts its device, and its own thread stops it at once; its frames
go only into the buffer that start held, which is freed unread. Which of Core Audio's calls
waits on a microphone prompt, `ma_device_init` or `ma_device_start`, is not known (§11): in
the second case a start given up while the prompt stands still turns the device on for a
moment once the person answers.

The voice pump settles a running start (the io takes the context and the device) or a failed
one (its word, once; nothing is left open) on the module thread. A Stop, Discard or close that
comes after the start returned but before any pump saw it finds nothing to let go, so the
module thread finishes the start itself, as the pump would, and closes a device it left
running. Whoever loses the swap never touches the job again, so exactly one side finishes it,
and a start that never returns holds its own job, buffer and thread, never the module thread.
At most four starts wait at once (`MaxStartsInFlight`); past them a start is refused
`device-start-slow`, so no caller can pile up threads behind a start that never returns.

The tests hold each of the three orders, every buffer freed in each:
- **The pump saw the start run, then a stop**: `audio_io_test` §7.
- **A stop or close before the start returned**, the start let go and finished by its own
  thread: `audio_io_test` §8 on `SyntheticAudioIo` with a held start (run or failed), and
  `audio_io_null_test` §6 on miniaudio's null device, 80 starts each stopped or closed at once,
  every one let go before its start returned; and §7, a start let go while held before its
  device started, starting none.
- **The start returned, then a stop or close before any pump saw it**, finished by the module
  thread: `audio_io_test` §8b (run or failed), `audio_io_null_test` §6b (the module thread
  closes the device the start left running, so frames stop at once), and `voice_live_test`
  §29c (Discard and close while the recorder still says `starting`).

The tests do not race the two threads at the swap itself: each order is set up one at a time.
That a swap lost by a hair is still safe rests on the compare-and-swap (`audio_io.nim`).

**Device lifetime.** A device is opened lazily, by `voice_record_start` or `voice_play`, on its
start thread, and released at the first pump after its stream ends (below). With the access
policy off, any caller can make those calls (§13). It is stopped and uninitialised on the
module thread, never from the callback: on stop, on done, and before the module unloads; a
start let go before it returned is stopped by its own start thread instead. That is the
`abandoned` lesson from the storage FFI (CLAUDE.md, pattern
sources). The module has no unload hook: the generated surface exports none (`muster_gen.nim`:
seven `logos_module_*` entry points and a constructor). So S7 does two things (built):
- **Every stream releases its device at the first pump after it ends.** At Stop, at
  `voice_play_stop` and at Discard at once; at the cap and at `done` when the pump next runs
  (`voice_status`, any other voice method, or `coordinate_intents`). The recorder stops the
  stream and closes the `AudioIo`: for `MiniaudioIo` that uninitialises the device and the
  context, so between streams nothing is open (`voice_live_test` §13 reads the null device's
  context back as gone; §19 holds Send and Discard while the draft plays, §20 a sink that
  refuses a write, §21 a start the device refuses and `close`). `MiniaudioIo` makes a new
  context at the next start. Nothing on the device side stops a stream, and the module has no
  clock, so until that pump a capture past the cap keeps the microphone open, dropping frames
  (the draft still ends at 60,000 ms), and a finished playback keeps the speaker open,
  playing silence. In Basecamp, with a room open, the room's ticks pump within a second;
  headless, or before the UI enters a room, nothing does (§13, §15).
- **An exit proc closes what still runs.** `muster_module` registers one (`std/exitprocs`)
  when it makes the recorder, and it calls `VoiceRecorder.close`. It runs at process exit,
  and when the plugin's image is unloaded, since `atexit` ties a handler to the image that
  registered it (Apple's libc by `dladdr`, glibc by the DSO handle). That window, a recording
  or a playback in progress when the host unloads the plugin, is not tested (§15).
  `close` never waits on a start in flight: it lets it go. The exit proc then waits up to
  2 s for start threads to return (`waitStarts`), so a start that lands just after `close`
  is closed by its own thread while the image is still mapped. A start that never returns
  costs those 2 s, never a hang: `logos_host` runs one module per process, so the process's
  exit ends that thread. An image unloaded without the process ending, while such a start is
  still blocked inside miniaudio, would leave that thread to return into code no longer
  mapped; that is not tested, and whether a host ever does it is not known (§15). In process,
  `voice_live_test` §31 makes it deterministic: close returns at once, and the bounded wait
  ends.

**The build** (built, S1–S3; the traps found on the way are in
`docs/labbook/voice-notes-audio-stack.md`):
- **libopus** comes from nixpkgs as libsodium does: `codegen.nim.link += "opus"` and
  `nix.packages.runtime += "libopus"` (`module/metadata.json:55`, `:173`).
- **miniaudio 0.11.23** comes in as a `codegen.nim.packages` fetch, pinned at
  `f40cf03f80cdb7e741d43e53b7e706e8c1394bcf` (the hash nixpkgs uses for its source). It is
  compiled into the staticlib with `{.compile.}`, with a global
  `{.passC: "-I<dir> -DMA_…".}` computed from `querySettingSeq(searchPaths)`.
  - **No C is tracked**, so `scripts/check-no-cpp.py:35-45` still passes.
  - **The flags are global** because the backend defines change struct layouts.
  - **Backends.** `MA_ENABLE_ONLY_SPECIFIC_BACKENDS` keeps CoreAudio, PulseAudio, ALSA and
    Null. The system IO never lists Null, so a machine with no backend says `no-device`, and
    never records zeros.
  - **Runtime linking is kept.** miniaudio dlopens the platform's audio libraries itself. On
    macOS the staticlib's new undefined symbols are `dlopen`, `dlsym` and `dlclose`, from
    libSystem (`nm -m` on S3's `.lgx`; the prototype had shown `_dlopen` alone). Framework entries
    on the flat link list would also land on the Linux link line.
- **The test harness** learns libopus and miniaudio as well: `module/tests/run-suite.sh` and
  the host-harness probe (`probe_return_marshalling_host.nim`), or the suite goes red (S1, S3).

## 10. Who sees what

| Observer | Sees | Never sees |
|---|---|---|
| room member (epoch-key holder when the note was sealed) | the note itself, played: the audio, its author (signed), its length and time | — |
| store node (delivery) | that the room's topic carried two frames of 90,153 B each, and when; the publishing node, unless `mix` is on; a frame that size marks a voice note | its length, which member sent it (FS-7), the audio |
| relay-mesh peers | the publishing node of each frame, as for any send, unless `mix` is on | the content, the member |
| mix node (`mix` on) | a hop of each frame, if mix carries frames this size: **untested** | the endpoints together |
| a module loaded beside Muster (access policy off) | the voice state and peak level; it can start a recording, in any room it makes the current one, send or discard the draft, play the draft or a note aloud (§13) | the audio, through any method: no voice method returns it, S6 closed `coordinate_graph`, and `coordinate_proof` refuses a room holding a voice note (below; a member's copy of a note this member's view does not hold is "What is left" there) |
| a module loaded beside another member's Muster from before voice notes (0.3.2 or earlier) (access policy off) | every note's clip, through that member's `coordinate_graph` and `coordinate_proof`, which return each part's value whole (§7; "What still leaks", item 6) | nothing of a note sealed in an epoch that member never held |

**Two methods that returned raw log content.** No voice method returns audio. But a part's
value holds its half of the clip as base64 Opus, and two existing methods handed event values
to any caller:
- **`coordinate_graph`**, the room map, copied every field of a JSON-object value into the
  entry's `content` (`room_graph.nim:198` on `main`), and did so for every entry (`:348` on
  `main`), so a voice part's `part` went with it until S6.
- **`coordinate_proof`** returns every raw log event, value and all (`proof.nim:79`,
  `muster_module.nim:3230`). A proof must carry each value whole: the verifier recomputes
  every event's id from it, and the id hashes the value's text itself (`muster.event.v1`,
  `log.nim:48-58`). So the field cannot simply be left out.

Left as they were, both methods gave any caller the Opus of every note in the room. That
contradicts the decision that audio plaintext never crosses IPC (§18), and §13. The two cases
differ:
- **`coordinate_graph`: S6 strips it.** An entry under `voice/` has as `content` its value's
  `v`, `ts` and `durMs` where each is an integer and its `digest` where that is 64 lowercase
  hex, and nothing else: no `part`, whatever a part holds (`voiceContentOf`,
  `voice.nim:314-336` on this branch, which reads a part's off the header the room's memo
  holds, §6). `voice_test` §14 pins that field by field, and
  finds no 48-character stretch of any half, taken at every 24-character step and at its end,
  in the map `toJson` gives.
- **`coordinate_proof`: refused until the maintainer decides** (§18). A room whose authentic
  view holds a part the fold stands (`voiceStanding`, §6's header pass: a part of a note
  complete, arriving or broken, as every member's own note is) exports no proof:
  `{error: "voice-notes-present", detail}` (`voice_live.roomProof`, `voice_live_test` §23,
  §26). Any other room exports its proof as before, with every entry under `voice/` that is
  no note's part: unsigned, a forged author, a malformed value, a squatted note id or a key
  of the wrong shape. Until PR 340's review the refusal took any `voice/` key in the raw log,
  and the log is append-only, so one member's junk entry switched the room's proof off for
  good; now only a note does. Any member can still do that, for good, by sending one note,
  a broken one included: two parts of their own, signed, whose clip fails its checks on
  purpose stand as a broken note, and a broken note refuses (`voice_live_test` §26). That
  lasts until §18's proof question is decided.
  - **What is left.** An entry that is no note's part leaves with the proof whole, as a
    message's body does. So junk that copies a note's bytes carries them out when this
    member's view holds none of that note's own parts: a note sealed in an epoch this member
    never held, re-posted in one they hold, or a note whose parts the fleet lost while the
    copy arrived. When the view holds the note, the note refuses the proof. A member who can
    play a note can post its bytes in a message's body as well, which `coordinate_messages`
    serves to any caller. `voice_live_test` §26 pins this case.

  That keeps the fixed decision that no hosted method returns a note's audio from this
  member's view, at the cost of no proof export for a room with a voice note. The maintainer
  then picks one of two. One option keeps raw values, since a proof accounts for every
  entry, and says here that a proof export carries the audio. That amends the IPC decision
  for this one explicit export. The other is a proof form that carries a voice part as a
  committed digest. Because today's id hashes the value itself, that means a new proof
  format, and perhaps a new id derivation, not a filter on today's.
- **Neither on an older client.** A member on a Muster from before voice notes (0.3.2 or
  earlier) holds the same parts and returns them whole through both methods; nothing in this
  PR reaches their code ("What still leaks", item 6).

**What the code adds** (built, S6). Every one of them takes a part to be what the fold
stands: `voiceStanding` (`voice.nim:300` on this branch), the header pass's standing parts of
the notes it keeps (§6 rules 2 to 4), by event id: exactly the ids `reduceVoice`'s notes name
in `parts`, whatever each note's state. So the flow, provenance and the room map agree with
the fold on what is a part, and an entry under `voice/` that is none, by its key, its value,
an equivocating later copy or a squatted note id, is no part in any of them.
- **A `voice/` branch in `flow.nim`** (`:126-138` on this branch). On `main` an unknown
  prefix falls through to envelope-only rows (`flow.nim:121-124`), which would show the room
  nothing about its own content. With the branch, each part shows:
  - room-member: `voice-note`, `voice-note-length`;
  - store-node: `timing`, `topic`, `fixed-size`.

  An entry under `voice/` that is no note's part shows the store node's three rows alone: the
  sending client's `session.publish` pads every `voice/` frame (§4), whatever its shape.
  Ingest does not check the size of a frame another member sent, so `fixed-size` on another
  member's entry is what an honest client sends. Pinned by `voice_test` §13.
- **The room map.** An entry of kind `voice`, its basis author-signed and its account the
  member its key names (`AuthorSigned`, `room_graph.nim:69`, `:82-83` on this branch). It is
  counted exactly when provenance lists it, so exactly when the fold stands it. An entry under
  `voice/` that is no note's part is still its signer's, since authorship proved who signed
  it, but uncounted (`room_graph.nim:378-383` on this branch), and its facet says so: "the
  fold counts it for nothing; its author signed it, bound to this room". The map's `file/`
  entries, account disclosures and ceremony joins, which provenance never lists and the map
  has always named by their signer, now say the same. The store node's facet
  names the one fixed size, which marks a voice note but not its length
  (`room_graph.nim:116-120` on this branch). Its `content` carries no `part` (above). Pinned
  by `voice_test` §14, the `file/` facet by `swarm_test` §8.
- **Provenance.** A `logProvenance` item (`intents.nim:829`, `:830` on this branch) for each
  standing part, as a peer message in its author's name at the epoch whose key opened it
  (`intents.nim:873-887` on this branch), and none for an entry that is no note's part.
  Pinned by `voice_test` §15.

`voice_test` pins those rows field for field, the way `swarm_test` §8 pins FileShare's.

**The claim** (built, S10: `contracts/claims/registry.json`, step `open-room`, under FS-9 and
worded narrowly; credibility imperative):

> **A voice note's length does not show in its size.** Muster sends each voice note as two
> parts, each one frame of one fixed size whatever the note's length, and a re-send is the same
> size. Each frame is sealed with the room's current key, as text is. So a store node can tell
> that a voice note was sent, to which room's topic and when, but not how long it is. It still
> sees the conversation graph (the gap above).

The claim is worded per frame, not per note: what stays fixed is each frame's size, not how
many frames a note takes, since a retried Send publishes both parts again. Its words keep to
the walkthrough's plain language (`scripts/ui-lint.sh`: no spec id or module name on screen,
and no developer term past `ui/tests/qmllint-baseline.json`), so the claim and the four gaps
below say "the room's key" for the epoch key and "access checks" for Basecamp's access
policy, and name no spec id.

Its test is `module/tests/probes/probe_voice_fixed_size_stepper.nim` (S5), which covers
durations from 0.5 s to 60 s, 0, 1 or 8 heads, and two epochs. It also publishes the same note
twice, so the second pair goes out on the held path (§4), and asserts that the topic carried
exactly four frames for the note, each 90,153 B. It sits beside the existing gap
*The store node still sees the conversation graph* (`contracts/claims/registry.json:83`) and
does not soften it.

**What still leaks.** The design note listed the first five, and the S6 review found the
sixth. Each stays true after this PR:
1. **A voice is a biometric, against FS-7.** FS-7 scopes a member's identity to the room. A
   voice undoes that for everyone who hears it:
   - a listener in two rooms can tell that the same person speaks in both;
   - a voice can tie a member to a real person;
   - nothing stops a listener re-recording playback.

   The draft surface says so before Send (§8).
2. **Size and timing are visible.** The store node sees the two frames at the moment of Send.
   Their size marks them as a voice note: chat frames are far smaller, and the largest
   events the tree sends today, Monero multisig blob parts, are of the same scale. Only the
   length is hidden. That takes the time between the two frames too: sent one part at a
   time, the second frame waited on its own signing, hashing and encoding, about 20 to 30 µs
   more per second of audio (0.36 ms for a 0.5 s note, 2.1 ms for 60 s, measured on
   darwin-arm64 outside the repo), and each Waku message carries its publisher's nanosecond
   timestamp, which the store keeps (`store_catchup.nim:149` on `main`). So Send signs,
   records and seals both parts first and then hands both frames to the transport back to
   back (`session.publishTogether`), with nothing between them whose cost depends on the
   note (`voice_live_test` §25; the same measurement then shows under 1 µs between the two
   calls at every length). What the delivery node adds between two sends of the same size
   on its side of the IPC hop is not measured (§15). Like text, the store keeps the
   ciphertext for as long as the fleet's capacity policy allows, and `room_journal` keeps it
   sealed on every member's disk. A note is exactly as forward-secret as the room's text: a
   later holder of that epoch's key opens it.
3. **Co-resident modules, with the access policy off** (§13).
4. **Leaving re-keys nothing.**
   - `coordinate_leave` announces nothing and re-keys nothing (`muster.lidl:133`).
   - No method removes another member: F-16's "Removing a member rotates the epoch
     immediately" is not built.
   - So a member who left can still open every later note, as they can open later text, by
     reading the topic again.
5. **No mix test.**
   - Nothing has sent a 90 KB frame under `mix = preferred | required`.
   - Whether delivery 0.3's mix path carries a frame this size is unknown.
   - Today a send that fails is visible only under `MUSTER_LP_DEBUG`.
   - Voice notes make no mix claim, and the gap *The store node still sees the conversation
     graph* (`contracts/claims/registry.json:83`) stays partial.
6. **An older client in the room returns the audio over IPC.** A member on a Muster from
   before voice notes (0.3.2 or earlier: every release so far, the published `muster-v0.3.0`
   and `muster-v0.3.2` among them; §18 asks that the release with voice notes be numbered so
   the line stays clear) opens every voice frame sealed in an epoch they hold, and serves
   each part's value whole, the base64 Opus included, to any
   module loaded beside it with the access policy off. Nothing in this PR reaches their code:
   - its session reads a padded frame unchanged: the pad is ASCII spaces after the JSON,
     which `decodeEvent`'s `parseJson` skips (`session.nim:82-90` on `main`);
   - its `authenticEventsWith` passes every event that `authorOf` does not mark authored
     (`authorship.nim:238-240` on `main`), and its `authorOf` has no `voice/` branch, so its
     room view keeps every part, a forged one too;
   - its room map copies every field of a value into `content` (`room_graph.nim:198`, `:348`
     on `main`), so its `coordinate_graph` returns `part`, and its `coordinate_proof` returns
     every raw value.

   So in a room with such a member, "audio plaintext never crosses IPC" (§18) holds on the
   machines of members who run this PR, not on theirs. Only that member's upgrading, or
   `--access-policy enforce` on their machine (§13), closes it. It is put to the maintainer in
   §18.

S10 carries four of these as gaps of their own in the registry (built, step `open-room`, each
`exposed`), unless the maintainer prefers them folded into existing entries. Item 2 is the
existing gap the claim names, and item 5 makes no claim:
- "A voice can identify the speaker" (status `none`: masking a voice would mean altering the
  audio, which voice notes never do; the party is everyone who plays the note);
- "Modules loaded beside Muster can record and send as you" (`partial`: `--access-policy
  enforce` with `infra/access-policy.json` ships in the host, off by default, and voice has
  not run under it; the party is the co-resident modules);
- "Leaving a room re-keys nothing" (`partial`: the key layer rotates on removal,
  `EpochCrypto.removeMember` (`epoch_crypto.nim:135`, exercised by
  `epoch_crypto_test.nim:61`), and no room path calls it; the party is a former member). It
  is a room-wide gap that no entry named before, and it leaves the F-16 protects claim at the
  top of the same step half true (§18);
- "A Muster from before voice notes hands them to the modules beside it" (`partial`: a
  member who runs a Muster with voice notes serves no audio, and nothing here reaches an
  older member's code; the line is drawn by the feature, with "0.3.2 or earlier" as today's
  releases; the party is the modules loaded beside an older member's Muster, on that
  member's machine).

## 11. macOS

Read on the installed `/Applications/LogosBasecamp.app` 0.3.2 (2026-10-21, with `codesign`
and `PlistBuddy`):
- `Contents/MacOS` holds `LogosBasecamp`, `LogosBasecamp.bin`, `logos_host` and `ui-host`.
  `logos_host`, where `muster_module` runs, and `LogosBasecamp.bin` are both signed with the
  hardened runtime (`flags=0x10000(runtime)`).
- `logos_host`'s entitlements are `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.disable-library-validation` only. There is no
  `com.apple.security.device.audio-input`.
- `Info.plist` has no `NSMicrophoneUsageDescription`.

What happens, observed on this Mac on 2026-10-22 (Basecamp 0.3.2, macOS 26.5, Apple Silicon;
throwaway profiles on `logos.dev`; the module at `bbae7d8`, before §9's start thread):
- **Basecamp launched the way the Dock launches it** (`open -n -a`). Pressing the microphone
  button, `logos_host` survived `voice_record_start`. No prompt appeared. tccd logged
  "Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires
  entitlement com.apple.security.device.audio-input but it is missing for
  responsible=LogosBasecamp", then "Policy disallows prompt", with `authValue=0`: macOS
  charges the request to Basecamp, will not ask the person about it, and denies it. The
  capture ran and every sample was zero (Send's `silent` takes a draft of at least 500 ms
  whose samples are all exactly zero). The banner said "The microphone is on, but no sound
  has reached it yet.", and Send showed "Nothing was sent. The recording is silent: no sound
  reached the microphone." with the Basecamp 0.3.2 note of the decision below. So the
  `silent` refusal is what a person sees, and nothing is posted.
- **A profile launched from a shell under Claude Code** was charged to Claude Code
  (`com.anthropic.claude-code`) instead, which is allowed the microphone, so it captured real
  audio. A test launched from a terminal is therefore not what a person's Basecamp does: its
  microphone is the permission of whatever app started the shell.

Before that run this section inferred two outcomes, zero-filled buffers (from Apple's
hardened-runtime rules and OpenJDK bug JDK-8244951) or TCC terminating `logos_host`, and said
a launch from Terminal would not help. The first is what happens; the last was wrong, since a
shell launch moves the request to another responsible app. Playback needs no permission.

Since Basecamp 0.3.2 is never prompted, its device start does not wait on a person. The start
thread and the 15 s bound (§8, §9) guard the hosts whose responsible app can prompt: a shell
or terminal launch, as below, and a future Basecamp that carries the entitlement and a usage
string.

The answer (decided):
- **Keep the record button.**
- **Refuse an all-zero recording at Send** with error `silent`. The module supplies the note
  (`hostOS == "macosx"`), so both UIs show the same words. Proposed wording: "Basecamp 0.3.2
  can't use the microphone on macOS yet: it lacks the microphone permission."
- **Never post silence.** A note of zeros would be a lie the card cannot show.

**The upstream ask** (not filed: filing is a public post, and that is the operator's call):
Basecamp adds `com.apple.security.device.audio-input` to `logos_host`'s entitlements (and the
app's), adds `NSMicrophoneUsageDescription` to `Info.plist`, and re-signs.

**Outside Basecamp, or Basecamp launched from a shell.** An unbundled, nix-built binary, and
Basecamp started from a shell, is charged to the app macOS holds responsible for it: the
terminal app, or the app that started the shell (S11's run, §17, names the one it was there).
While that app's permission is undecided, macOS asks the person to grant it the microphone,
and Core Audio holds the device's start while it asks: in S11's first run the start had not
returned after 20 s, with the prompt unanswered. That the start returns once the person
answers is inferred, since nobody answered it. Once the app is allowed, as Claude Code was on
this Mac later that day, capture hears the microphone (above, and §17 S11's microphone leg).
S11's opt-in microphone test runs only with the person's consent. Since PR 340's review the
module starts the device on a thread of its own (§9), so a prompt like that holds that thread
only: `voice_record_start` answers at once, `voice_status` says `starting`, the room says
"Starting the microphone…" and that nothing is recorded until it starts, and 15 s after the
call the recording ends with `device-start-slow`, its start let go. If the person allows the
microphone after that, the start returns and its own thread releases the device: if the
prompt held `ma_device_init`, the device is never started; if it held `ma_device_start`, the
device comes on for a moment and that thread stops it at once (§9; which call it holds is not
known). Either way the next Record starts at once (inferred, as above: not seen with a real
prompt). A start that never returns costs its thread and its buffer until the process ends,
never the module thread.

## 12. Linux

There is no Linux host here. On Linux, the maintainer ran the module suite and checked the
package's load in PR 340's review (x86_64, at `bbae7d8`), and the fork's CI, in a workflow
that is not part of this PR, ran the suite on both arches and S9's voice self-test (§15):
- **The module suite, the maintainer's run:** `module/tests/run-suite.sh` gave 285 passed, 0
  failed, among them `voice_clip_test`, `voice_codec_test`, `audio_io_test`,
  `audio_io_null_test`, `session_pad_test`, `voice_test`, `voice_live_test` and the three
  voice stepper probes. That run linked nixpkgs' libopus 1.6.1, as run-suite then did on
  Linux; it links the builder pin's 1.5.2 there since the review (§15).
- **The module suite on the fork's CI.** Run 39836679442 (`bbae7d8`'s tree, on
  `ubuntu-latest` and `ubuntu-24.04-arm`, `JOBS=4`): on each, 284 of 285 passed, and the one
  that failed, `room_graph_scale_test`, failed on its own timing beside the other tests and
  passed alone. It linked 1.6.1 too. Run 40030788377 ran it at `08dfcb3` on both arches. Its
  first test step, the voice and audio tests (`run-suite.sh voice audio session_pad`), passed
  on each. The whole suite then gave 284 of 285 on each, four at a time, and the one that
  failed was `room_graph_scale_test` again, on its own timing (its folds took 4,021 ms on
  `ubuntu-24.04-arm` and 5,658 ms on `ubuntu-latest`, against a bound of 4,000), and it
  passed alone, as the workflow re-runs it, its folds taking 1,497 ms and 1,197 ms there.
  On this Mac, alone, three runs each, its folds took 554–605 ms on this branch and 555–562
  ms on `main` (`67701f8`), and the whole `reduceRoomGraph` 617–646 ms and 590–592 ms, about
  6% slower; `main` has not run on those runners. `voice_codec_test` §1 printed `libopus 1.5.2,
  preskip 312` on both arches (read from the run's kept logs), so the suite links the
  shipping 1.5.2 on Linux too.
- **The package loads.** In the fork's `lgx variants` run (39776903474), `linux-amd64` carries
  `libopus.so.0` beside the plugin with RPATH `$ORIGIN`, and `ldd` resolves every library the
  plugin needs, libopus from the package itself, against the Qt in Basecamp 0.3.2's AppImage.
  So a missing codec does not take down `muster_module` there.

**The devices, as the code behaves today** (read from the code and the review, not run):
- **What miniaudio loads.** `abSystem` lists PulseAudio, then ALSA, and never Null (§9). At a
  Record or a Play, on the start thread, miniaudio dlopens `libpulse.so` or `libpulse.so.0`,
  then `libasound.so.2`, by soname. PipeWire answers through `pipewire-pulse`, where that is
  installed. No permission prompt is involved on Linux.
- **A nix-built runner** (`make run`, the self-tests): nix's glibc does not read
  `/etc/ld.so.cache`, so a dlopen by soname likely finds neither library, and the review
  expects `make run` to report no device. Then Record answers `{ok}` at once; once the start
  thread returns, the next `voice_status` (it pumps before it answers) shows the recording
  idle, with `recording.error` and `ready.capture` both `no-device`, and `starting` shows
  only to a read that lands before that; the room says "No microphone was found on this
  device." Play ends the same way: "No speaker was found on this device." Nothing records
  zeros, since Null is not on the list: such a machine refuses with the device word, and
  never makes a silent note for Send's `silent` to refuse.
  - The fix to try: `libpulseaudio` in `nix.packages.runtime`, so its lib dir joins the
    plugin's RUNPATH, which a dlopen from the plugin searches.
  - The list is flat, so it would enter the darwin closure too.
  - A runner that drops nim.link libraries from RUNPATH has bitten before
    (`docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md`).
- **Inside Basecamp's AppImage**, with the portable `.lgx`: unverified. If `logos_host` there
  runs on the system's loader, which reads `/etc/ld.so.cache`, the distro's `libpulse.so.0` or
  `libasound.so.2` resolves (inferred, not checked); no Record or Play has run in it, so
  whether a device opens there, and in which format, is not known.
- **Not known either:** a PipeWire host without `pipewire-pulse`, an ALSA-only host, and
  whether every device on them reads back as 48 kHz mono s16 (`device-format` otherwise).

## 13. Co-resident callers, with the access policy off

Basecamp runs with the access policy off by default, so any loaded module can call any other
(`docs/basecamp-access-policy.md:3`, `side-modules.md:102`). A Nim provider cannot see its
caller. So any module loaded beside Muster can:
- call `voice_record_start` and turn on the microphone. The cap ends the recording at 60 s,
  but the device stays open until something pumps (§9), so a caller that makes no further
  call keeps the microphone on past it where nothing else calls the module: headless, or with
  Muster's view not running (the view's 1 s read of `voice_status`, on every page since PR
  340's review, pumps it);
- choose where the note goes. `coordinate_join` makes any room the current one, one the
  module founds there and then or one whose members it admitted (`coordinate_admit`), and
  `voice_record_start` binds the draft to the current room, so the module can record there
  and send, and the member's voice reaches whoever is in that room;
- send the draft, with `voice_draft_send`, before the member decides. The note is signed with
  the member's key, as `coordinate_post_message` already lets such a module post text in the
  member's name;
- destroy the draft, with `voice_draft_discard`, before the member decides;
- play the member's unsent draft through the speaker, with `voice_play("draft")`. The draft is
  the one piece of audio this design otherwise keeps inside the module until Send;
- play any complete note aloud, with `voice_play`;
- poll `voice_status`. Its `peak`, read and reset at the poller's own rate, is a coarse loudness
  envelope of a recording in progress (S7 reports no level for a playback). S7 serves it
  raw; whether to coarsen it (one value per 100 ms, a few levels) is still open (§18).

What it cannot do is read audio through a voice method: none returns it, and `voice_status`
carries state, position and peak only. That is unlike `coordinate_messages`, which serves
room plaintext to any caller (`side-modules.md:104`). Two methods that returned raw log
content, `coordinate_graph` and `coordinate_proof`, would have handed it the clip. S6 closed
the first. The second refuses a room holding a voice note until the maintainer decides between
an exception and a new proof form (§10, §18); an entry under `voice/` that is no note's part
leaves with the proof, so a member's copy of a note this member's view does not hold leaves
too (§10, "What is left"). On the machine of a member
who runs a Muster from before voice notes (0.3.2 or earlier), both still return it, and
nothing here reaches that code (§10, "What still leaks", item 6).

**The mitigations:**
- **A strip above every page** (since PR 340's review, which asked for "a global recording
  indicator in `Main.qml`"). `Main.qml` reads `voice_status` every second, whether or not a
  room is open (`appVoicePoll`). While it says `starting` or `recording`, a strip above every
  page (Home, Settings, Contacts, Learn, the Wallet, any room) says "Muster is using the
  microphone", or "Muster is starting the microphone…", with the time, Stop and Discard, and
  "If you did not start it, press Discard." Its Stop and Discard go through the room's own
  calls, so in a room's view their answers show in the room's banner (`RoomVoiceNote.qml`),
  which shows there as well. On any other page the answer is said where the button was
  pressed (since the final check of PR 340's review fixes found that nothing said it, and the
  strip just went): a recording kept ("Stopped. The recording is kept, unsent: you send it
  from its room.") or discarded ("Discarded. Nothing was sent.") once, in the toast; a
  refusal, such as a Stop while the microphone was still starting ("Nothing was recorded:
  the microphone had not started yet."), in the strip's place, in the room banner's words
  (`MusterStyle.voiceRefusalWords`, which both now read), until it is dismissed, the
  microphone comes on again, or a room's view opens. What it does not cover:
  - Muster's view not running: headless `logoscore`, a host that has not loaded Muster's
    view, and, in Basecamp, whether Muster's view keeps running while another app's view is
    in front is not checked;
  - a person who is not looking;
  - a recording that starts and ends between two reads: Send takes 500 ms of audio at least,
    so a caller can start, stop and send a note of about a second that the strip never shows
    (the note itself then shows in that room's thread, as the member's);
  - who started it, and for which room: `voice_status` names neither (§18);
  - a draft held, or a note or the draft played aloud: the strip is for the microphone only.

  The operating system's own microphone indicator still shows, where capture works. The
  strip, and what its Stop and Discard say off a room's view, are seen in the gallery only
  (`home-voice-indicator`, and `room-voice-record` for a
  room), against the generated fake backend: no runner or Basecamp window has shown it.
- **The real fix** is `--access-policy enforce` with `muster_module`'s allowed callers set to
  `muster_ui` (`docs/basecamp-access-policy.md`, `infra/access-policy.json`), or Basecamp's
  capability broker.

## 14. F-13: a message in another medium

F-13 closes the render vocabulary: `message`, `intent`, `fact`, `choice`, `artifact`,
`receipt`, plus system notices. Additions to it are core releases (`docs/01-furps.md:25`). This
design classes a voice note as a **message** in another medium:
- one member's words to the room;
- no agreement and no chain;
- authored and signed like text.

It is not an `artifact`. F-17 ties artifacts to Logos Storage content addressing
(`01-furps.md:29`), and a note rides the log.

`CardVoiceNote.qml` extends the UI's concrete card set, not the class vocabulary. The mic is
an `IconAction` in the message row (`RoomComposer.qml:1254-1314`, beside the existing send
`IconAction` at `:1305-1313`), not a
tile in `RoomActionPicker`, which is titled "Propose something" and whose every tile is an
intent. If the maintainer reads a new medium as a vocabulary addition, this is a core release,
and the PR says so (§18).

## 15. What is not verified

S1–S10 are built (§17). Of S11, the real-device test is built and both its legs have passed
on this Mac: the speaker leg on 2026-10-22, before the start thread, and on that thread in
S2's review; the microphone leg at `bbae7d8`, before it; and both again at `08dfcb3`, on it
(§17 S11). A note has crossed the live fleet from one headless host to another three times,
outside Basecamp and with no UI, twice before §9's start thread and once at `08dfcb3`; from
one Basecamp 0.3.2 profile to another in Basecamp's own window, where the `silent` refusal of
a capture of zeros was seen too, at `bbae7d8`, before the start thread; and between two
runners on the fork's Linux CI, in S9's self-test, which failed at `bbae7d8` on its own
reading of the logs, B having played the note, and passed at `08dfcb3` (below). Among what
has still not run: a start on the start thread while a permission prompt stands, anything
since `bbae7d8` in Basecamp's window, Record and Play inside Basecamp's AppImage, S9's
self-test on the Nim UI's runner and its red run against a runner with no autopilot,
`ui-parity.sh voice` for either UI, `grade-specs.sh`, and any real device on Linux
(PulseAudio, then ALSA, §12; only miniaudio's null device has run there). What is
unverified, built or planned:
- **Some audio facts are still the prototype's** (a throwaway on an Apple M5): the cost of
  encoding and decoding 60 s (§3.1, §9), and the fixed-arity binding's wrong read-back
  (§3.1; in this build a fixed-arity mutant failed `OPUS_BAD_ARG` instead, labbook §1). The rest has run through the
  real `logos-module-builder` derivation since: S3 built the `.lgx` (`nix build
  .#lgx-portable`, miniaudio compiled in through `{.compile.}`, `nm` showing `T
  _ma_context_init`), `voice_codec_test` holds the 40 B packets on the shipping libopus
  1.5.2, and S7's `.lgx` ran the null backend in `logos_host` (below). On Linux it has run
  in the module suite, the maintainer's (x86_64) and the fork's CI's (both arches) on libopus
  1.6.1 at `bbae7d8`, and the fork's CI's again at `08dfcb3`, on the shipping 1.5.2; and in
  the package's load (§12).
- **A real microphone in a person's Basecamp.** Observed on 2026-10-22 at `bbae7d8` (§11): in
  Basecamp 0.3.2 launched as the Dock launches it, `logos_host` survives `voice_record_start`,
  tccd disallows the prompt because the audio-input entitlement is missing ("Policy disallows
  prompt", `authValue=0`), the capture is all zeros, and Send refuses it `silent` with the
  Basecamp 0.3.2 note, posting nothing. So on macOS no person's Basecamp 0.3.2 records sound;
  that waits on the upstream ask (§11). Real capture has run only where the responsible app is
  allowed the microphone: `voice_device_e2e`'s microphone leg (§17 S11), and a Basecamp profile
  launched from a shell under Claude Code (§11). The microphone leg has run on §9's start
  thread since, at `08dfcb3` (§17 S11); the shell-launched Basecamp profile has not.
- **A device start held the module thread: fixed in this PR** (PR 340's review, its second
  should-fix; §18). On a Mac where the responsible app can prompt for the microphone (it has a
  usage string, and the permission is not decided), Core Audio's device start waited for the
  permission prompt, and nobody answered it: `voice_device_e2e`'s `startCapture` had not
  returned after 20 s (S11). The module started the device on its own thread, so that
  thread, and every module call behind it, could wait with it; the C++ UI calls
  `voice_record_start` synchronously, so its view would have frozen too. Now a device starts
  on a thread of its own, `voice_status` says `starting` until it runs, and a start still
  pending 15 s after the call ends with `device-start-slow` (§8, §9). What ran, on this Mac:
  - `audio_io_test` §7–§9 and `voice_live_test` §29–§31, written first and run red on the
    seam as it was, whose start blocked its caller ("the start returns at once while the
    device start is held: 1774 ms"; "voice_record_start answers at once while the device
    start is held: 1760 ms", a safety net releasing the held start after 1.5 s), then green:
    the call under 100 ms with the start held, `coordinate_messages`' rows and
    `voice_status` answering meanwhile, the recording timed and capped from the device's
    start, Stop (`not-started`), Discard and close letting the start go and its thread
    freeing the buffer once released (the buffers counted), a failed start idle with
    `no-device` in `recording.error` and `ready.capture`, one past 15 s `device-start-slow`,
    and the same for Play;
  - `audio_io_null_test` §6 on miniaudio's null device thread: 80 starts each stopped or
    closed at once, 80 of them let go before their start returned, every buffer freed; and
    §1–§4 pumping until the start lands before they read the device back;
  - added by the slice's review, for the order §6 never reached (a start that returned before
    any pump saw it, then a stop, Discard or close): `audio_io_test` §8b, `audio_io_null_test`
    §6b and `voice_live_test` §29c (§9). Each was run against two mutants in a scratch copy:
    `SyntheticAudioIo` no longer finishing such a start (§8b red, "buffers left 1"; §29c red,
    "the buffer freed at once: 1 left"), and `MiniaudioIo` forgetting it instead of settling
    it (§6b red, the context not kept by the stop; §29c red on the null device, "1 left");
    green on the code as it is;
  - also from that review: `voice_live_test` §29d, `ready` saying `unknown` for a device
    whose start is on its way (red before: `ready.capture` still `device-start-slow` from
    the last start while the next one was `starting`), and `audio_io_null_test` §7, a start
    let go before its device started starting none (red before: "1 device(s)");
  - the host probe (`probe_return_marshalling_host`): its `voice_status` and the six voice
    methods as before, with no room joined;
  - `ui-nim/tests/autovoice/run.sh`, against a fake module whose recording is `starting`
    for 1.5 s: red on the backend before this change ("the fake never said recording": its
    Stop came while starting and was answered `not-started`), green on this one (recording
    1,994 ms after Start, Stop about a second after that);
  - the gallery fixture `room-voice-starting` (below).

  What has run since: `voice_device_e2e`'s speaker leg on the start thread (it pumps until a
  start lands, under its watchdog), in S2's review and again on its fixes, Core Audio's start
  landing and playing as before. Then, on 2026-10-23 at `08dfcb3`: both its legs, so a real
  microphone's start on its start thread, with the responsible app already allowed the
  microphone and no prompt standing (§17 S11); the start thread in a host, miniaudio's null
  device in logosctl 0.3.2's `logos_host` (the headless run below) and in a Linux runner (C in
  S9's self-test, below); and the C++ autopilot's wait for `recording`, in S9's runners. What
  has not run: a start while a prompt stands, or a prompt answered while a start waits; the
  start thread in Basecamp's window, and the C++ autopilot's wait there; and an image
  unloaded while a start is still blocked (§9). A person's Basecamp 0.3.2 is never asked
  (§11: tccd disallows the prompt), so there a start does not wait at all; the start thread
  matters where the responsible app can prompt (§8).
- **A device past the end of its stream.** The cap and `done` are noticed by the voice pump
  alone (§9), so with nothing calling the module the microphone stays open past 60 s (a
  review probe on the null device: still capturing 63 s after the start, 2,880,000 frames,
  closed by the first `voice_status`), and a finished playback keeps the speaker open. A
  device-side stop (a watchdog thread that calls `ma_device_stop` once `capped` or `done` is
  set) is not built.
- **Linux devices** (§12): miniaudio's dlopen of `libpulse` and `libasound` from a nix-built
  runner (the review expects no device, and the code then refuses `no-device`), from the
  portable `.lgx` inside Basecamp's AppImage, and PipeWire. None has run.
- **The suite's libopus on Linux.** Since PR 340's review `run-suite.sh` links the builder
  pin's libopus 1.5.2 on Linux too, the one the `.lgx` ships, where it linked nixpkgs' 1.6.1:
  for `x86_64-linux` the pin's `libopus.out` evaluates to
  `/nix/store/39jlnb9vgammhav2skbf3dvkbciqsh14-libopus-1.5.2.drv`, built on glibc 2.40-66,
  under nixpkgs' gcc on glibc 2.44-25. Its `libopus.so.0`, read from cache.nixos.org, needs
  only `libm.so.6` and `libc.so.6`, at `GLIBC_2.2.5` to `GLIBC_2.29`, with RUNPATH the pin's
  glibc; a test links libc and libm itself (Nim's `std/math`, which `strutils` imports, passes
  `-lm`), so the gcc's glibc is the one loaded. That is read and evaluated. The fork's CI ran
  the voice and audio tests at `08dfcb3` on both arches, and they passed, `voice_codec_test`
  §1 printing `libopus 1.5.2` on each (§12).
- **Delivery of two 90,153 B frames:**
  - over the live fleet, past the headless runs on `logos.dev` (below; the last two with
    `publishTogether`, which sends the two back to back) and the `logos.dev` leg of S9's
    self-test on the fork's CI (below);
  - with RLN on `logos.test`, where each note spends two sends;
  - under `mix = preferred | required`.

  And a failed delivery is not seen. `DeliveryTransport.publish` is fire-and-forget (§8), so
  if either frame fails on the fleet, `voice_draft_send` returns `{note}` and drops the
  draft, and the note can stay `arriving` for every other member: no path re-sends it
  (§18). The retry of §8 covers only a transport that raises, and
  `voice_live_test` §15 raises through a `LocalTransport` subscriber, a failure the hosted
  module never sees.
- **A half-sent note looks whole to its sender.** `session.publish` logs a part before the
  transport sees it, so after a Send that fails between its parts the sender's own thread
  shows the note complete while the room may hold only its first part (`voice_live_test`
  §15 pins both views). A retry closes it; Discard instead makes the split permanent. Only a
  transport that raises shows that failure, and the hosted one never does (above), so S8's
  draft surface has no answer for it: it does not warn that the room may hold half of it, nor
  hide Discard then. `too-large`, which no draft under the cap can get, it answers with
  "Discard it and record it again", promising nothing of a second Send.
- **A UI from before S8 draws a note as an empty line** (§7). `coordinate_messages` returns a
  note's row with an empty `body`, which the RoomThread on `main` draws as an empty chat line
  under the author's name, as any older UI paired with this module would. S8 (built) draws it
  as a card; S8 and S7 should land in one push.
- **S8 is seen through the gallery, on a Mac, with no module, and once in Basecamp's window.**
  The S8 fixtures (`room-voice-forged`, `-notes`, `-record`, `-refused`, `-flow`, `-starting`,
  `room-map-voice`, and since PR 340's review `home-voice-indicator`) pass against the real `Main.qml` and the generated `FakeBackend.qml`,
  offscreen with Qt 6.9.2's software renderer (icons draw blank there) and both design systems,
  Basecamp 0.3.2's and the runner's; their voice rows, `voiceJson`, `voiceResultJson` and its
  count `voiceResultSeq`, `flowJson` and the room map's voice entries are typed from the shapes
  the module's code and tests give, not recorded: no runner has recorded them, since S9's
  self-test has run only on the fork's Linux CI, offscreen, recording nothing (below). The
  C++ UI has reached a real `muster_module` in Basecamp
  0.3.2's window, at `bbae7d8`: the microphone button of §11, and a note drawn and played
  between two profiles (below). The Nim backend is type-checked only against stubs made from
  the `.rep` and `muster.lidl` (ui-nim builds on Linux only), its voice autopilot run against a
  fake module (S9, below), and it has drawn no note from a real room. What S2 and its review's
  fixes added to the QML since (the `starting` banner, the not-started words), and the strip
  above every page, what its Stop and Discard say on a page with no room view, and the
  poll's new cadence (§8, §13), have run in the gallery only.
- **The cost of store catch-up.** It returns each payload as a JSON byte array
  (`delivery.nim:309-315`), so a voice frame inside the 60 s lookback is re-fetched as several
  hundred KB of JSON per query. That should be measured before anything is added; a seen-frame
  short-circuit only if it matters.
- **The cost of the fold.** `eventId`'s memo key concatenates the whole value
  (`log.nim:71-76`), and every hosted read re-runs `roomEvents` with no fold cache (the cache
  is `side-modules.md` S4, `exo-ff5.4`, not built). Since the final check of the review's
  fixes this is measured (§6), in a bench outside the repo, for one room of 20 notes of 60 s
  with a warm memo: `roomEvents` about 3.0 ms, `coordinate_messages`' rows and
  `coordinate_conversations`' `lastTs` about 6.4 ms each, the flow about 7.6 ms and the room
  map about 27 ms past their own `roomEvents`: about 12 ms of each second with the map closed
  and 27 ms with it open. No part is parsed; the values' bytes are copied and hashed in each
  pass, so it should grow with each full note (notes of 1 s cost about a fifteenth of it). Not
  measured: the whole of `coordinate_conversations` (its other folds), a room of more notes,
  and any host but this Mac. The fix to try is an event id carried with the
  event from ingest, a change to the log's `Event` that this PR does not make.
- **The room's memo in the hosted methods.** `voice_live_test` §27 and §28 drive the
  recorder procs the hosted methods call (`rows`, `lastTs`, `flowRows`, `graphOf`,
  `provenanceOf`) and `forgetRoom`, over the room's memo. No test runs the hosted lines
  that call them on a room holding a note: `coordinate_conversations`' `lastTs` for each
  joined room, `coordinate_flow`, `coordinate_graph`, `coordinate_provenance`, and
  `coordinate_leave`'s `voiceForgetRoom` (`muster_module.nim` on this branch), which drops a
  left room's memo. The marshalling probe compiles them but calls none of them. S9's
  self-test, which joins a room (below), calls only `coordinate_conversations`, once in each
  runner as it joins, before the room holds a note, and checks nothing it returns.
- **Audio over `coordinate_proof`** (§10). It refuses `voice-notes-present` for a room whose
  authentic view holds a part the fold stands, so no proof of a room with a voice note leaves
  the module until the maintainer decides; `voice_live_test` §23 and §26 hold the refusal on
  `roomProof`, which the hosted method calls after its `not-joined` check and a poll. An
  entry under `voice/` that is no note's part refuses nothing and leaves with the proof
  whole, so junk that copies a note's bytes carries them out of a room whose view holds none
  of that note's parts (§10, "What is left"): §26 pins that in process, and no run has
  looked for it on the fleet. S6 stripped the audio from the room
  map: an entry's content is `v`, `ts`, `durMs` and `digest` at most, and `voice_test` §14
  finds no 48-character stretch of any half, taken at every 24-character step and at its end,
  in the map `toJson` gives. So a leaked stretch of 71 characters or more is caught wherever
  it sits in a half; a shorter one, or the clip in another encoding than its base64, is not
  looked for.
- **Audio over an older client's IPC** (§10, "What still leaks", item 6). A member on a
  Muster from before voice notes (0.3.2 or earlier) returns every part whole through their
  `coordinate_graph` and `coordinate_proof`, to any module loaded beside them. This PR cannot
  change that code, and no test here runs such a client against a voice note: what it does
  is read from `main`'s source.
- **The size budget** (§5) is measured in process only. The record's size is S1's arithmetic,
  and the worst case's JSON and frames are measured over `LocalTransport` (S4, S5). A note's
  two frames have crossed `logos.dev` in the headless runs below and in S9's self-test on the
  fork's CI, but no frame's size was read there.
- **The voice methods through a host** (S7). `voice_live_test` runs `VoiceRecorder` in
  process, on `SyntheticAudioIo`, `FileAudioIo` and miniaudio's null device, with two members
  over `LocalTransport`, and holds the rows `coordinate_messages` serves (`messagesJson`, §22)
  and `coordinate_proof`'s refusal (`roomProof`, §23), the two procs those hosted methods
  call. The marshalling probe compiles the hosted glue in `muster_module.nim` and calls the
  six methods through the generated dispatch with no room joined, each reply checked to the
  byte (`not-joined`, `not-recording`, `no-draft`, `ok`), and `coordinate_messages` and
  `coordinate_proof` beside them; no device opens. With a room joined, the glue's remaining
  lines (the `not-joined` check, a poll, the session and keystore it passes) have run through
  a host in one test in the tree, S9's self-test: on the fork's Linux CI, where it passed at
  `08dfcb3`, each runner's C++ autopilot called `voice_status`, `voice_record_start`,
  `voice_record_stop`, `voice_draft_send` and `voice_play` in a joined room, in standalone
  runners, not in Basecamp (below); it calls neither `voice_draft_discard` nor
  `voice_play_stop`. Outside any test, the same autopilot made those calls in Basecamp's
  window at `bbae7d8`, and the scratch harness of the next entry in logosctl's `logos_host`.
  Before all of that the glue was driven once by hand, headless, in logosctl 0.3.2's
  `logos_host` on darwin-arm64 (2026-10-21, the S7 `.lgx`, a throwaway room joined on
  `logos.dev`): with `MUSTER_VOICE_SOURCE` a 3 s 1 kHz WAV and `MUSTER_VOICE_SINK` a scratch
  file, `voice_record_start` refused `not-joined` before the join and gave `{ok}` after it,
  Stop made a draft (8,700 ms: the WAV's 3 s, then the silence `FileAudioIo` hears after it),
  `voice_play("draft")` wrote 8,700 ms to the sink with the source's 1 kHz power in its
  first 3 s, and Discard, `busy`, `no-draft`, `unknown-note` and `not-recording` answered as
  §8 says; on `MUSTER_VOICE_BACKEND=null` the null device's zeros were refused at Send as
  `silent` with the macOS note as `detail`, and nothing was posted. Since then a note has gone
  from one host to another (next entry).
- **A note between hosts, headless, outside Basecamp (2026-10-22, and again on 2026-10-23).**
  Three logosctl 0.3.2 hosts (`aarch64-macos`) ran on this Mac, each its own daemon, with
  `muster_module` from this branch built at `ff071e3`, in one room on the `logos.dev` fleet.
  A harness (scratch, not in the tree) made the module calls the UI's slots make:
  `coordinate_join`;
  `coordinate_request_join` sent again every 3 s, as `scheduleJoinRetry` does;
  `coordinate_pending` and `coordinate_admit`; `coordinate_intents` and `coordinate_messages`
  as the 1 s tick; on A, `voice_record_start`, `voice_status`, `voice_record_stop` and
  `voice_draft_send`, with `MUSTER_VOICE_SOURCE` a 3 s 1 kHz WAV; on B, `voice_play` and
  `voice_status`, with `MUSTER_VOICE_SINK`. What it gave:
  - A's draft was 4,777 ms: the WAV's 3 s, then silence, since the recording ran about 4.8 s
    while the harness's status calls took that long. A sent it as note
    `836b8a66b39f3d4488f706ae95f11eaf`.
  - B's thread showed it complete about 1 s after the Send. B played it to its end:
    `voice_status` named it playing, then `playing` was null.
  - B's sink held exactly 229,296 samples, 4,777 × 48. From 0.25 s to 2.75 s the 1 kHz
    Goertzel power was 0.99 of the source's, and over 8 × 10⁸ times that at 500 Hz, 1.5 kHz
    and 3.1 kHz (S9's script asks for half, and 100 times).
  - C, on `MUSTER_VOICE_BACKEND=null`: Stop gave `{durationMs 3130, silent true, peak 0}`,
    Send was refused `{"error":"silent","detail":"Basecamp 0.3.2 can't use the microphone on
    macOS yet: it lacks the microphone permission."}`, and 8 s later B's thread still held
    exactly one voice row.
  - A first attempt failed only because the harness sent `coordinate_request_join` once: no
    admission in 180 s. Sent again every 3 s, as the UI does, admission took about 7 s.
  - **Run again on `bcc5bad`**, the same harness with `muster_module` rebuilt from that commit,
    so it covers `2656f71`'s module changes too: a note's two parts published together and
    sent back to back (`session.publishTogether`, `authorship.publishAuthoredTogether`,
    `voice_live`'s `draftSend`), a retried Send sealing the author's own copy (`copyToSeal`,
    `publish(asGiven)`), and `log.variantsOf`. A's draft was 4,809 ms, sent as note
    `118285bbfbd549ecaf334107358d5cd4`; B's thread showed it complete about 1 s after the
    Send, B played it to its end, and B's sink held exactly 230,832 samples, 4,809 × 48, with
    the same 1 kHz figures. C's Send was refused `silent` with the same `detail`, and B's
    thread still held one voice row.
  - **Run again on 2026-10-23 at `08dfcb3`**, after §9's start thread, by a harness making the
    same module calls, with `muster_module` built from that commit and logosctl 0.3.2 the
    official `aarch64-macos` release tarball (sha256 `f78e8ffd…`). A and B are on
    `FileAudioIo`, which starts at once, with no start thread; C, on
    `MUSTER_VOICE_BACKEND=null`, is `MiniaudioIo` on the null device, so C's start went
    through the start thread inside logosctl's `logos_host`. A's
    draft was 4,894 ms, sent as note `4efda2a32d6b3b5822f7fe84d1e4b8f2`; B's thread showed it
    complete about 1 s after the Send, B played it to its end, and B's sink held exactly
    234,912 samples, 4,894 × 48, with 0.99 of the source's 1 kHz power. C's
    `voice_record_start` answered `{ok}`, its Stop gave a silent draft (3,140 ms, peak 0), its
    Send was refused `silent` with the same `detail`, and B's thread still held one voice row.

  What it does not cover: no UI, so no QML, neither backend and no autopilot (it is not S9's
  self-test, below); no Basecamp window (on 2026-10-22 the screen was locked, and the
  window's checks ran later that day, next entry; nothing has run in the window since the
  start thread); no real microphone or speaker (`FileAudioIo` on A and B, the null device on
  C); and C's own copy of A's note was not checked, only B's.
- **A note between two Basecamp 0.3.2 profiles, in its own window (2026-10-22, at `bbae7d8`).**
  Two throwaway profiles in one room on `logos.dev`, each with the C++ UI and its autopilot
  (§17 S9). A's autopilot recorded the 1 kHz WAV and sent it; B's thread drew the card, and B's
  autopilot played it into its sink: exactly 137,808 samples, 2,871 ms × 48, with the tone at
  0.99 of the source's power. What it does not cover: a real microphone or speaker (the WAV
  source and the PCM sink, `FileAudioIo`); the Nim UI; and everything since `bbae7d8`, S2's
  start thread among it, so neither the `starting` state nor the autopilot's wait for
  `recording` has run in a window.
- **S9's self-test has run only on the fork's Linux CI: at `bbae7d8` it failed there on its
  own reading of the logs, and at `08dfcb3`, reading them as it does now, it passed.**
  On the contributor's fork, a workflow that is not part of this PR built the runner from
  `bbae7d8`'s tree, and later `08dfcb3`'s, on GitHub's `ubuntu-latest` and ran the script on
  both fleets:
  - Runs 39776743154, 39822900956 and 39836679442 failed both legs, `logos.dev` and
    `MUSTER_FLEET=local`, with "FAIL: B never played A's note (sent: 48410f05…, played: 0)".
    The product had done its part. In 39836679442's kept logs B was admitted before A
    recorded, B's thread held the note complete, B's Play answered ok, `voice_status` named
    it playing (990 ms, then 1,990 ms) and then nothing, and B's sink held exactly 143,280
    samples, 2,985 ms × 48, with 0.99 of the source's 1 kHz power (the local leg: 2,984 ms).
    From A's Stop on, delivery accepted two of A's sends and refused none.
  - The script misread the logs. The C++ UI's lines do not reach them bare: ui-host relays
    them a chunk at a time, `ui-host [ "muster_ui" ]: "<chunk>"`, QDebug-quoted, several of
    the UI's lines to a chunk. The script only turned `\"` into `"`, so every VOICE line kept
    the chunk's closing quote, or the next line joined to it by a literal `\n`, and each
    `json.loads` failed and was swallowed. Run 40005318158 patched the runner's checkout of
    the script to read the relay unquoted and passed both legs, C's included: C's Stop
    called its draft silent (peak 0), its Send was refused `silent`, C's thread held no note
    and B's held one.
  - The same logs show ui-host cutting lines as well. A chunk can end inside one of the UI's
    lines, its rest in the next chunk (210 to 240 times in each log), and another process's
    line can land inside a relayed one (20 to 30 times in each). Since PR 340's review the
    script reads its logs through `ui_log` (`scripts/lib/ui_log.py`), which undoes the
    quoting and both cuts: in those four logs all 1,960 voice lines read as JSON, where the
    patched run's reader left 8 that did not, 7 of them in the local leg's A. A line the
    script cannot read is named as the script's error, never as what B did.
    `VOICE_REPLAY=<dir>` gives the verdict on a finished run's files, and
    `scripts/tests/voice-self-test-replay.py` holds it, with no runner, on lines cut from
    39836679442's logs: SUCCESS on the run as it was and on the same logs with B's lines cut
    as ui-host cuts them, FAIL for each way a run can fail, and the same on the logs written
    bare, as the Nim UI writes them. With `bbae7d8`'s reading put back in the script it is
    red: "the script could not read A's Send … {"note":"48410f05…"}"", the quote that
    reading left. Replayed on 39836679442's whole kept logs and sinks, the script as it is
    now says SUCCESS on both legs (143,280 and 143,232 samples, 0.99 of the 1 kHz power).
    Against a stand-in runner (scratch, not committed) that relays the autopilot's lines as
    ui-host does and cuts most of them: SUCCESS, C's leg included, and FAIL when A's Send is
    refused or B never stops playing; `bbae7d8`'s script against it fails as CI did,
    "played: 0".
  - **At `08dfcb3` it passed** (2026-10-23, run 40030788377, job "voice self-test (runner,
    ubuntu-latest)", on `08dfcb3` plus the fork-only workflow commits, branch
    `ci/voice-notes-linux` at `7fe3812`, which are not part of this PR).
    `python3 scripts/tests/voice-self-test-replay.py` said "all passed", `BUILD_MEM= make
    build` built the runner, and the script ran three standalone runners, A, B and C, on one
    `ubuntu-latest` machine, on the C++ UI. On `logos.dev`: SUCCESS, note `89d79b72…`; B's
    sink held 143,280 samples, 2,985 ms × 48, its 1 kHz power 66,639,028 of the source's
    67,095,156; from A's Stop on, delivery accepted 2 of A's sends and refused none; C's Stop
    called its draft silent (peak 0), its Send was refused `{"error":"silent","detail":""}`
    (the module gives the Basecamp note on macOS only, §11), C's thread held no note and B's
    exactly A's. With `MUSTER_FLEET=local`: SUCCESS, note `477737db…`, B's sink 143,328
    samples, 2,986 ms × 48. C, on `MUSTER_VOICE_BACKEND=null`, started its device through the
    start thread, and the C++ autopilot timed A's and C's seconds from the first
    `voice_status` that said `recording`. Offscreen, the C++ runner loads no QML view, so no
    voice QML ran, as the script says.
  - Not run yet: the script on the Nim UI's runner (`make build-nim`, then `MUSTER_UI=nim
    scripts/voice-self-test.sh`) or with `MUSTER_QPA=xcb`, so no voice QML has run in a
    runner; the `voice` entry of `ui-parity.sh`, for either UI; and the red run against a
    runner with no autopilot (below).

  `scripts/voice-self-test.sh` (§17) needs the standalone runner, and the runner does not
  build on this Mac. `BUILD_MEM= make build` on 2026-10-22
  (macOS 26.5, Apple Silicon, Command Line Tools and no Xcode; 1 h 28 min from cold) stopped
  in lez_core 0.5.0's Rust dependencies, `logos-execution-zone-wallet-ffi-deps-0.1.0`:
  `risc0-sys` 1.5.0's build script runs `xcrun --sdk macosx metal`, the Command Line Tools
  carry no Metal compiler (`xcrun: error: unable to find utility "metal"`), and
  `risc0-build-kernel` 2.0.1 panics "Could not build metal kernels". `libmuster_module`, the
  `muster_ui` plugin and `logos-standalone-app` had built by then. So on this Mac no note has
  crossed two runners on either UI, on `MUSTER_FLEET=local` or a fleet; on the fork's CI one
  has, on the C++ UI (above). (A note did cross from one headless host to another, with no
  runner, no UI and no autopilot, and between two Basecamp profiles, with the C++ UI and its
  autopilot but no runner, the entries above: neither is this test.) What did run, on darwin:
  - the Nim autopilot, in `ui-nim/tests/autovoice/run.sh`, which compiles
    `ui-nim/app/backend.nim` whole against stubs made from the `.rep` and `muster.lidl` and
    a fake module with §8's state machine, and runs its timers in real time, with nim 2.2.12
    from ui-nim's own nixpkgs pin. It was a scratch harness in S9 and is committed since
    S9's review. On `9cc1005`'s backend: no voice call and no `VOICE` line. With S9's: Start,
    Stop a second later and Send, once each (since PR 340's review the fake's recording is
    `starting` for 1.5 s, as the module's now is, and Stop comes a second after the first
    `voice_status` that says `recording`); Play for each complete note from another
    member, one at a time, once each, and never for an arriving note, one's own, or a
    message whose body claims a note; a refused Play tried five times, no more. Six mutants
    are each caught: no self check, no played set, no complete check, Play while one plays,
    no limit on tries, and Stop not waiting `VOICE_SECS`;
  - the self-test's audio check, on the tone round-tripped through the shipping libopus
    1.5.2 at §3.1's settings (from 0.25 s to 2.75 s: 1 kHz power 66.6 M of the source's
    67.1 M, at most 2.6 at 500 Hz, 1.5 kHz and 3.1 kHz) and on sinks made to fail it
    (silence, one millisecond short, a 1.5 kHz tone, a quarter of the amplitude, a 3.1 kHz
    tone added, a row arriving or of another length);
  - `scripts/lib/ui-build.sh`'s launch and cleanup with a stand-in runner: macOS has no
    `setsid`, and its `ps` has no session id, so before S9 a self-test launched nothing
    there and could leave a runner's children running;
  - the script itself, under macOS's bash 3.2, against a stand-in runner (not committed)
    that writes the autopilot's log lines for its role and that round-tripped tone as B's
    sink: SUCCESS, and FAIL for a sink one millisecond short, a quarter of the amplitude, a
    send delivery refused, C's note not refused, and A never sending; no process was left.
    S9's review found four holes there, each now closed and each shown red on S9's script
    and green on the fixed one, against the same stand-in: a refused frame whose result
    came back before the UI logged the Send, and no send result at all, passed (the count
    now starts at A's Stop and wants two accepted); C's Stop calling its draft not silent,
    C's thread holding a note of its own, and, on macOS, C's refusal with no `detail`,
    passed; and a `VOICE_SECS` of 2 failed whatever B heard, the filter's window being
    fixed at 0.25 s to 2.25 s (it now ends 0.25 s before the note or the WAV does: 1 and 2
    pass against the stand-in, and 0 or 2.5 is refused before anything launches). The
    whole-diff review found two more, each now closed and shown on the same kind of stand-in:
    both autopilots log `voice_status` once a tick, before they decide to Play, so a note of
    a second can end before B's next tick logs it playing, and the script waited out its
    240 s and failed (it now takes the Play's own answer, ok, as B playing it: red on the old
    script, `FAIL: B never played A's note (sent: ab12cd, played: 0)`, green on the new); and
    a `VOICE_SECS` past 60 could never fit the wait (now refused up front, as 61 is).

  The C++ autopilot ran in Basecamp's window at `bbae7d8` (above), before S2 made it wait
  for the first `voice_status` that says `recording`; with that wait it has run in the fork's
  CI runners at `08dfcb3` (above), and not in a Basecamp window.

  **What the maintainer runs on Linux before S9 counts as done** (the PR stays a draft, and
  this entry stays, until the transcripts exist): `make build && scripts/voice-self-test.sh`
  and the same with `MUSTER_FLEET=local`, which the fork's CI has run at `08dfcb3` (above);
  `make build-nim` and `MUSTER_UI=nim scripts/voice-self-test.sh`; `scripts/ui-parity.sh
  voice` for each UI; and one red run, the script against a runner built from `9cc1005` (no
  autopilot), which must FAIL with "B never played A's note (sent: none".
- **The voice gallery fixtures break the gallery's own rule.** `ui/tests/gallery/CLAUDE.md`
  says fixture data is recorded, never hand-typed. S8's voice fixtures (`room-voice-notes`,
  `-record`, `-refused`, `-flow`, `-forged`, `-starting`, `room-map-voice` and
  `home-voice-indicator`) are typed from the
  module's shapes (above), and S9's recorded ones, the card complete, playing, arriving and
  broken and the message row recording and holding a draft, are not made:
  `scripts/ui-screenshot.sh record scripts/voice-self-test.sh` needs a runner, Xvfb and Qt's
  xcb platform, none of which this Mac has. That self-test drives one good note, its
  playback and C's silent refusal, so on Linux its snapshots can replace `room-voice-record`
  (recording, the draft), the complete and playing rows of `room-voice-notes`,
  `room-voice-flow`, the voice entries of `room-map-voice`, and the silent refusal in
  `room-voice-refused`. It makes no broken note, no reliably caught arriving one (B holds one
  part only between two frames sent back to back), and no `busy`, `room-changed`,
  `too-large`, `codec` or device word. Those, like a forged body, which no runner sends, are
  a recorded snapshot with that one row or answer edited, and the fixture says which. Until
  then the PR lists this as an open breach of that rule.
- **The exit proc at unload** (§9). In that run `module unload muster_module` with a
  recording open on the null device took `logos_host` down with no crash report, and a
  reload answered idle; whether the exit proc ran then, rather than the process being ended
  without it, is not observed. (The daemon's stop afterwards crashed `delivery_module`'s own
  `logos_host`, in `DeliveryModuleCdylibProvider::emitTrampoline` on its event thread. That
  was not investigated, and no run of `origin/main` was made to compare, so whether this
  branch has any part in it is not known.)
- **The time between a note's two frames, past the module.** Muster hands the two frames to
  `delivery_module` back to back (§10, item 2), but each Waku timestamp is set by the
  delivery node, after the IPC hop, and what that node does between two sends of the same
  size (on `logos.test`, an RLN proof each) is not measured, so neither is the spacing a
  store node records.
- **Checks that are Linux-only or the maintainer's:**
  - the runner self-tests and `ui-parity.sh` for both UIs, `scripts/voice-self-test.sh` and
    its `voice` entry among them (S9, above): the C++ UI's runner passed
    `voice-self-test.sh` on both fleets on the fork's CI at `08dfcb3`; the Nim UI's runner
    has not run it, and `ui-parity.sh voice` has not run for either;
  - the Nim UI's `contract_test`;
  - `scripts/grade-specs.sh`, `exo-526` above all: its host probe now links libopus, through
    `.probe-env/opus`, a path no Mac run takes. Since the final check of PR 340's review fixes
    it links the builder pin's libopus 1.5.2, the `.lgx`'s, as `run-suite.sh` does
    (`module/tools/builder-nixpkgs.sh` reads the pin for both): for `x86_64-linux` that
    evaluates to `/nix/store/mzksc9fpj2hvhvr8ggzqcy0j96fyqr79-libopus-1.5.2`, where it took
    nixpkgs' current one, `/nix/store/ah26jmgs60s1dzphf0vi4f9pqmlpl9y6-libopus-1.6.1`
    (`nix eval`, 2026-10-23). Not run: this Mac has no exophial, and the script links
    `libsodium.so` and `libopus.so`, Linux's names;
  - the Linux plugin links, by `lgx-variants.yml` on the fork (S3 linked darwin-arm64 only).
    Each Linux variant's bundled lib directory must hold `libopus.so.0`, and the plugin's
    `NEEDED` and `RUNPATH` must resolve it. The plugin links libopus at load (on darwin a
    plain, non-weak `@loader_path/./libopus.0.dylib`), so a variant without it fails all of
    `muster_module` to load, not only voice. `dlopen`, `dlsym` and `dlclose` must resolve from
    glibc there. **`linux-amd64` is checked**, by the maintainer in PR 340's review (§12):
    `libopus.so.0` beside the plugin, RPATH `$ORIGIN`, every `NEEDED` resolved against the Qt
    in Basecamp 0.3.2's AppImage. `linux-arm64` is not named there;
  - the module suite on Linux since the review: its libopus (above), and the run-suite rule
    that only a test in the E2E list may skip (§17 S11). The fork's CI ran it at `08dfcb3`:
    on both arches 284 of 285 passed, `room_graph_scale_test` failing on its timing and
    passing alone, and `voice_codec_test` linked libopus 1.5.2 (§12).

## 16. Invariants, checked

| # | How voice notes keep it |
|---|---|
| 3 | No plugin is involved. The core captures, encodes, seals and plays. |
| 4 | Notes are `reduceVoice(roomEvents(log))`, order-free and idempotent, and a property test permutes and duplicates the parts (S5 §9). The draft is not state: it is never posted until Send, and it is lost with the process. |
| 5 | The clip is a CDE record. The note id and the clip digest are hash-input records (`muster.voice.note-id.v1`, `muster.voice.clip.v1`). Values hold no float. |
| 7 | Parts are sealed under the epoch they were sent in. A later joiner never opens them, and v1 has no re-share. |
| 8 | Nothing new runs on a server: no relay, no storage, no service. |
| 9 | A note is named for its author only by its author's signature, and a forged or squatted part drops out. A `message/` cannot pose as a note: only the fold sets a row's `voice` field (§7). |
| 1, 2, 10 | Not bound: a note signs nothing for a chain and enters no effect. Attaching a note to an intent would make its digest an external read (F-20), and that is out of scope. |

## 17. Order of work

Each slice's test is written and run red before its code (worker.md), and every commit carries
`Tested-Behavior` or `TDD-Exempt`. S9's is the exception so far: `scripts/voice-self-test.sh`
has run on real runners only on the fork's Linux CI, red at `bbae7d8` on its own reading of
the logs and green at `08dfcb3` (§15), and its red run, against a runner with no autopilot,
has not run. How it reads its logs is held red and green with no runner, by
`scripts/tests/voice-self-test-replay.py` and a stand-in runner.

- **S0 — this document** (TDD-Exempt: docs).
- **S1 — The Opus binding, the clip record, the codec.** `audio/opus.nim`, `voice_clip.nim`
  (pure CDE), `voice_codec.nim`, plus libopus in `metadata.json` and `run-suite.sh` (the
  builder pin's 1.5.2, the `.lgx`'s, on macOS and, since PR 340's review, on Linux: §15). Tests:
  `voice_clip_test` and `voice_codec_test`. The ctl read-back is the arm64 guard. It tells a
  fixed-arity binding from a varargs one only on darwin-arm64, so it must run on this Mac. On
  Linux it cannot tell the two apart (§3.1).
- **S2 — The `AudioIo` seam and miniaudio on the null backend.** Tests: `audio_io_test` and
  `audio_io_null_test`, which cover the cap, `capped`, `busy` and idempotent uninit.
- **S3 — A native build gate.** `voice_status` in `muster.lidl`, with the marshalling probe
  linking libopus and miniaudio.
- **S4 — Fixed-size sealed frames.** `session.publish(padTo)`, the `voice/` key rule (§4) and
  `FrameTooLarge`. Test: `session_pad_test`.
- **S5 — Events, authorship, the fold, thread rows.** `coordination/voice.nim`, the `authorOf`
  branch, `voice_test`, `authorship_test` §11, and three stepper probes: fixed size (with the
  held-path case of §10), author, and order. The author probe includes a forged row: a
  member's `message/` that claims `voice-note` with another member's nid. `threadRows` gives
  it no `voice` field, so it neither renders as a voice card nor plays under the forger's name
  (§7); S8 pins the render side.
- **S6 — Disclosure.** The `flow.nim` branch, the room map and provenance, with the rows pinned
  in `voice_test`. A `voice/` entry's room-map `content` carries no `part` (§10), pinned field
  by field.
- **S7 — The hosted surface and its state machine (built).** `voice_live.nim`, the six
  remaining methods, `voicePump`, and `threadRows` in `coordinate_messages`, and `close` before
  the module unloads (§9). The recorder keeps a `VoiceMemo` per room and passes it to every
  `threadRows`; `coordinate_conversations`' `lastTs` reads `threadLastTs` (§6). Since PR 340's
  review the memo keeps each part's header as well, `threadLastTs` and Play read through it,
  and leaving a room drops its memo; since its second pass, the flow, the room map and
  provenance read through it too, and each hosted method calls the recorder's proc
  (`lastTs`, `flowRows`, `graphOf`, `provenanceOf`) that `voice_live_test` §28 drives.
  Until the maintainer decides (§10), `coordinate_proof` refuses a room holding a voice note.
  Since the review's second should-fix a device starts on a thread of its own: Start and Play
  answer at once, the recording is `starting` until the device runs, and a start that fails
  or is still pending after 15 s ends in its word (§8, §9). Test: `voice_live_test` on
  `SyntheticAudioIo` and `LocalTransport`, which holds §8's type rule (no float) in every
  state, `starting` among them, and the marshalling probe's not-joined replies.
- **S8 — The UI (built).** The `.rep` (SLOTs `loadVoice`, `startVoiceRecording`,
  `stopVoiceRecording`, `sendVoiceDraft`, `discardVoiceDraft`, `playVoiceNote(noteId)`,
  `stopVoicePlayback`; PROPs `voiceJson`, `voiceResultJson` and, since `adb9812`,
  `voiceResultSeq`), both backends (ADR-019),
  `CardVoiceNote.qml` (pure render from the row's `voice` field), the mic in the message row
  and `RoomVoiceNote.qml` above it (the recording banner whoever started it, the draft with
  Play, Send, Discard and §8's disclosure, the module's refusals and notes), Room's 250 ms
  poll while the microphone starts or records or a note plays (and, until PR 340's review,
  while a draft was held), the voice words in FlowView and the room map, the regenerated
  gallery `FakeBackend.qml`, and the unknown-kind fallback. Since that review `Main.qml` reads
  `voice_status` every second on every page, room or none, and shows the microphone in a
  strip above every page while it starts or records, with Stop and Discard, whose answers
  on a page with no room view are said there: the toast for a recording kept or discarded, a
  notice in the strip's place for a refusal (§13; gallery `home-voice-indicator`). The
  gallery fixture `room-voice-forged` holds a forged `voice-note` body, and RoomThread draws
  it as plain text under its poster's name, with no voice card and no Play (§7).
- **S9 — End to end (built; the self-test ran on the fork's Linux CI at `bbae7d8` and failed
  there on its own reading of ui-host's relay, B having played the note, and reading the logs
  as it does now it passed there at `08dfcb3`, on the C++ UI; its module calls ran three
  times from one headless host to another on `logos.dev`: §15).**
  `scripts/voice-self-test.sh`, in `fileshare-self-test.sh`'s shape: two offscreen runners in
  one room, each with a scratch HOME. A records `VOICE_SECS` (3; a whole number from 1 to 60,
  as both autopilots read it) seconds from a 3 s 1 kHz WAV the script writes
  (`MUSTER_VOICE_SOURCE`) and sends; B plays the note into a PCM file (`MUSTER_VOICE_SINK`).
  It passes when A logs the note it sent;
  from A's Stop on, delivery accepted at least two of A's sends (the note's two frames,
  whose results come back whenever they do) and refused none; B's thread holds that note
  complete and B logs it playing (a `voice_status` naming it, or its Play's own answer, ok),
  then nothing playing; B's file holds exactly the draft's
  samples with the 1 kHz tone (a Goertzel filter over the tone's part of the note: at least
  half the source's power, over 100 times that at 500 Hz, 1.5 kHz and 3.1 kHz); and no log
  has a QML TypeError or ReferenceError, which holds the voice QML only on `MUSTER_UI=nim`
  or `MUSTER_QPA=xcb`: offscreen, the C++ runner never instantiates the view, and the script
  says so. Then C joins on `MUSTER_VOICE_BACKEND=null`: its
  Stop must call the draft silent, its Send must be refused `silent` (on macOS with the
  microphone note as `detail`), its own thread must hold no note of its own after the Send,
  and B must hold one note still (`VOICE_SILENT=0` skips C). The autopilot,
  in both backends (ADR-019): `MUSTER_AUTOVOICE=<seconds>` is the mic's Start, Stop and Send
  (the seconds counted from the first `voice_status` that says `recording`, since the module
  starts the device on a thread of its own)
  once someone else is in the room; `MUSTER_AUTOVOICEPLAY=1` is the card's Play for a
  complete note another member sent, while nothing plays, a refused Play tried again up to
  five times; each tick logs `VOICE` (voice_status), `VOICE-NOTES` (the thread's `voice`
  fields) and each call's `VOICE-RESULT`. The UIs still only trigger and poll. The script
  reads those lines through `ui_log` (`scripts/lib/ui_log.py`): the C++ UI's reach the logs
  through ui-host's relay, quoted and now and then cut, the Nim UI's bare. A line it cannot
  read is reported as the script's error. `VOICE_REPLAY=<dir>` gives the verdict on a finished
  run's files, and `scripts/tests/voice-self-test-replay.py` holds that verdict on lines cut
  from a Linux CI run.
  `ui-nim/tests/autovoice/run.sh` holds the Nim autopilot's decisions against a fake module,
  on a Mac as on Linux. A `voice` entry in `ui-parity.sh`, which refuses a bash older than 4,
  and `scripts/lib/ui-build.sh` launching and cleaning up on macOS too.
- **S10 — The claim, docs, labbook and layout (built).** The protects claim and four gaps of
  §10 in `contracts/claims/registry.json`, with `ClaimsRegistry.qml` regenerated
  (`ui/tools/gen-claims-qml.py`). Also `docs/labbook/voice-notes-audio-stack.md`, the CLAUDE.md
  layout, and `module/tests/README.md`'s real-device gate. Not done, and not in S8 either: the
  plan's optional mock of the mic and the voice card in `ui/prototype/desktop-v3.html`. It is
  dropped from this PR as optional, as FileShare's card has no mock there; the gallery's
  `room-voice-*` shots show what it would.
- **S11 — Checks on a Mac display, the opt-in device test, and the draft PR.** First, before
  anything relies on the `silent` refusal: under Basecamp 0.3.2, with a throwaway profile,
  does `logos_host` survive `voice_record_start`? If it does not, that goes back to the
  operator (§11). Checked on 2026-10-22, at `bbae7d8`: it survives. tccd disallows the
  microphone prompt for want of the entitlement, the capture is all zeros, and Send refuses
  it `silent` with the macOS note (§11). In Basecamp's window a note also crossed from one
  profile to another (§15). Earlier that day, with the screen locked, a headless run with three
  logosctl 0.3.2 hosts ran instead (§15), twice: a note from A's WAV to B's sink over
  `logos.dev`, and C's null device refused `silent` with the macOS note, in logosctl's
  `logos_host`, not Basecamp's.

  **The device test (built): `voice_device_e2e`**, in run-suite's E2E list and gated behind
  `MUSTER_VOICE_REAL`. Without it, it prints a `SKIP` line and exits 0, and run-suite counts it
  as skipped. Only a test in that list may skip: since PR 340's review run-suite fails any
  other test that prints such a line, saying so, since a skip there would hide a test that
  never ran. It opens `MiniaudioIo` on the system backend through the `AudioIo` seam, with
  no mock (`module/tests/README.md` has the details):
  - **The microphone leg** (`MUSTER_VOICE_REAL=mic`, or `1`), only with the person's consent.
    It captures 2 s. The stream must read back as 48 kHz mono s16, frames must arrive at 48 a
    millisecond (±5%), the write index must only grow, and the cap must stop it at exactly
    96,000 frames with `capped` set. Then the capture goes through the module's libopus path
    at §3.1's settings and back, its length kept. It prints only the capture's peak and RMS,
    and writes nothing. An all-zero capture fails, naming the likely cause: the microphone
    permission, or a default input that hears nothing (muted, or a virtual device with
    nothing playing into it). `MUSTER_VOICE_REAL` must name a leg: any other value fails,
    separators alone (`,`) included, which before the review passed with nothing run.
  - **The speaker leg** (`speaker`, or `1`) plays digital silence by default, so nothing can
    be heard; only `MUSTER_VOICE_REAL_AUDIBLE=1` plays 0.5 s of 440 Hz at about -30 dBFS. It
    must run at 48,000 frames a second (±5%), and a short buffer must be `done` only after the
    device's own tail of silence, as on the null device. `audio_io` sets `done` only past that
    tail, so this guards the rule rather than measuring when the sound is heard.
  - **A watchdog thread** ends the test, with a message, when a device call has not returned
    after 20 s. It ends the whole test, so a leg after the one that stalled does not run (the
    speaker leg below was run alone for that reason); a leg that fails a check is recorded,
    and the next leg still runs. Since the review's second should-fix a start returns at once
    and the device starts on a thread of its own (§9), so the test pumps until the start
    lands, and the watchdog times that (20 s), as it times a stop or close (10 s); a start
    call that takes 100 ms or more to return fails the leg. Since that change the speaker
    leg has run on Core Audio, in S2's review (48.24 frames a millisecond) and again on its
    fixes (48.15), each `done` after the 1,920-frame tail; both legs have since, at `08dfcb3`
    (below).

  **Run on this Mac, 2026-10-22** (macOS 26.5.2, Apple Silicon, outside Basecamp, run from Claude
  Code in the Claude desktop app, with the person's consent; `MUSTER_VOICE_REAL=1`, then
  `MUSTER_VOICE_REAL=speaker`):
  - **The speaker leg passed** on Core Audio, playing silence. It read back as 48 kHz mono s16,
    took 48,480 frames in 1,010 ms (48.00 a millisecond), and a 100 ms buffer was `done` after
    130 ms, once 1,920 frames of silence had followed it. That is the tail the device read
    back (40 ms), the same as the null device's: miniaudio's buffer and periods, not Core
    Audio's output latency, which is not measured. A second run, on the committed text, gave
    the same numbers but 127 ms.
  - **The microphone leg's first run got no frame.** macOS asked for the microphone and nobody
    answered: it was the middle of the night. Core Audio held the device's start while it
    asked, so `startCapture` had not returned after 20 s, and the watchdog ended the test. So
    that run had no peak, no RMS and no codec round trip from a real microphone. tccd's log
    charged the request to Claude Code (`com.anthropic.claude-code`, its own `claude.app`,
    which the Claude desktop app starts through its `disclaimer` helper), not to the Claude
    desktop app: `AUTHREQ_PROMPTING` for `kTCCServiceMicrophone`, then no result. A minute
    later, a preflight for the speaker run still read the permission as not decided
    (`authValue=1`). It was not run again that night. After that run its messages were reworded
    to name Claude Code, and the cap's pace is now timed from the start's return; neither
    touches the step where it stopped. Since the review the messages name the responsible app
    in general terms, not one tool; a review re-run while that prompt still waited stalled the
    same way, and tccd logged only a preflight for it, so the watchdog's log hint now reads the
    last hour.
  - **Before it, the same test on the null device** (a scratch mutant, not committed: the
    system backend swapped for null): with the backend checks in, both legs FAIL "backend
    Null not in @["Core Audio"]"; with them out, the microphone leg FAILs on its all-zero capture with
    the permission message, after every other check passed (48.13 frames a millisecond, capped
    at exactly 96,000 after 2,010 ms, 101 packets of 40 B, a 4,318 B record decoded back to
    96,000 samples), while its speaker leg passes.
  - **The microphone leg passed later that day, at `bbae7d8`**, run with the person's consent
    once the microphone was allowed: Core Audio read back as 48 kHz mono s16, 48.37 frames a
    millisecond, capped at exactly 96,000 frames, a peak of -41.2 dBFS, and the codec round
    trip kept 96,000 samples. That was before §9's start thread.

  **Run again on this Mac, 2026-10-23, at `08dfcb3`**, on §9's start thread (macOS 26.5.2,
  Apple Silicon, outside Basecamp, `MUSTER_VOICE_REAL=1`, launched from a shell under Claude
  Code, whose responsible app, `com.anthropic.claude-code`, is allowed the microphone, so no
  prompt stood). Both device starts went through `MiniaudioIo`'s start thread. PASS, both legs:
  - **The microphone leg.** Core Audio read back as 48 kHz mono s16, its first frames after
    15 ms; 48,000 frames in 1,004 ms, 47.79 a millisecond; capped after 1,996 ms at exactly
    96,000 frames; a peak of 172 (-45.6 dBFS), RMS 23.9 (-62.7 dBFS). libopus 1.5.2 took the
    96,000 samples into 101 packets of 40 B (a record of 4,318 B) and decoded them back to
    96,000 samples. Opus is lossy, so only the length is checked.
  - **The speaker leg**, on digital silence: its first frames taken after 15 ms; 48,480
    frames in 1,007 ms, 48.10 a millisecond; a 100 ms buffer `done` after 131 ms, past the
    device's tail of 1,920 frames (40.0 ms).

  What it still does not show: a start while a permission prompt stands, since none stood.

  **What is left:** the microphone leg's start on that thread while a permission prompt
  stands, and once it is answered, which needs a responsible app whose permission is not
  decided, and the person's consent (`MUSTER_VOICE_REAL=mic module/tests/run-suite.sh e2e
  voice_device_e2e`). Linux has not run it (§12): PulseAudio, then ALSA, with no permission
  prompt there.

## 18. Decisions

Decided by the operator (2026-10-21):
- **Length.** At most 60 s.
- **Codec.** libopus, hard CBR at 16 kbps, 48 kHz mono, 20 ms frames, DTX off, FEC off.
- **Shape on the wire.** Every note is exactly two author-signed parts, and each sealed frame
  is padded to 90,112 B of plaintext (`VoiceFrameBytes`), through `session.publish(padTo)`.
- **Carrier.** Room events, not FileShare (§2).
- **Where audio lives.** Capture, playback and Opus live in `muster_module`, and audio
  plaintext never crosses IPC.
- **macOS.** Keep the record button, and refuse an all-zero recording as `silent` with the
  Basecamp 0.3.2 note (§11).
- **Process.** Open as a draft PR that asks the maintainer for an exo id and for spec sign-off.

Asked of the maintainer (corpetty):
- **An exo id for the epic.** Until it exists, commits use the `voice-notes` scope, and nothing
  touches `.pebbles/`.
- **The typed spec.** It would be `derived-exo-<id>`, through `discuss-issue`, with your
  sign-off. The probes are written in stepper form now, as its oracles.
- **The wire format, §3–§5.** S4–S10 are built on it in this PR, so an objection now means
  reworking them; after a release, changing it strands notes already sent. The alternative
  was 12 kbps in one 128 KiB frame.
- **F-13** (§14): is a voice note a message in another medium, or a core vocabulary addition?
- **`derived-exo-526`'s oracle.** S3 added `voice_status` to its host probe: the method listed
  as `QString`, `ready.codec` the libopus linked, both devices `"unknown"`. S7 added the six
  other voice methods, `coordinate_messages` and `coordinate_proof`, each with no room joined
  and checked to the byte. The spec's
  acceptance criterion still names only `health()`, `propose()` and `status()`, so a voice
  regression now turns exo-526 red. Sign off on the wider oracle, or a voice spec's own probe
  takes these checks over once the epic has an exo id.
- **A device start with no timeout** (§15): **done in this PR** (the review's second
  should-fix), the first of the review's two options, the device started off the module
  thread and its state reported through `voice_status`, with a 15 s bound as well. On a Mac
  where the responsible app can prompt, Core Audio's device start waited for an unanswered
  permission prompt (S11), so the module thread could wait with it, and every module call
  behind it. Now the device starts off the module thread:
  `voice_record_start` and `voice_play` answer at once, `voice_status` says `starting` until
  the device runs, a start that fails ends in its word, one still pending 15 s after the call
  ends in `device-start-slow` with its start let go, and Stop, Discard and close never wait on
  a start (§8, §9). Basecamp 0.3.2's `logos_host` is never prompted (§11: tccd's policy
  disallows the prompt, since the entitlement is missing), so in a person's Basecamp 0.3.2 on
  macOS a start does not wait at all. The start thread and the bound guard hosts whose
  responsible app can prompt, a shell or terminal launch, where the wait was seen (S11), and a
  future Basecamp that carries the entitlement and a usage string. The maintainer may still
  object: to the bound (15 s), to the word, or to a start thread at all for a wait today's
  Basecamp never has. A real microphone's start on that thread has run, on this Mac at
  `08dfcb3`, with the responsible app already allowed, so no prompt stood (§17 S11); a start
  while a prompt stands has not (§15).
- **An indicator outside the room** (§13): **done in this PR**, as the review suggested ("a
  global recording indicator in `Main.qml` would close most of it"). `Main.qml` reads
  `voice_status` every second on every page, room or none, and while it says `starting` or
  `recording` a strip above every page says Muster is using the microphone, with Stop and
  Discard; on a page with no room view what they got back is said there (§13), and in a
  room's view the room's banner says it, beside the strip, so a room's view shows both. The
  claims registry's gap "Modules loaded beside Muster can record and send as you"
  says what it covers and what it does not: Muster's view not running, a person not looking,
  a recording started and sent between two reads, who started it or for which room, which
  `voice_status` does not say, and a draft held, or a note or the draft played aloud, since
  the strip is for the microphone only. Seen in the gallery only. The maintainer may still
  object to its words or its place, or to a room's view showing the strip and the room's
  banner both, each with its own Stop and Discard (gallery `room-voice-starting`), which this
  PR keeps.
- **The Linux-only checks** (§12, §15). This PR is built on a Mac. On Linux the maintainer
  ran the module suite (x86_64, at `bbae7d8`), and the fork's CI ran it on both arches and
  S9's self-test on the C++ UI (§12, §15). Still not run on Linux: the device backends of §12
  (PulseAudio, then ALSA), Record and Play inside Basecamp's AppImage, the Nim UI's runner and
  its self-test (`make build-nim`, then `MUSTER_UI=nim scripts/voice-self-test.sh`),
  `scripts/ui-parity.sh voice` for either UI, S9's red run, the Nim UI's `contract_test`,
  `grade-specs.sh`, and `linux-arm64`'s plugin links (§15). Since the review the suite links
  the shipping libopus 1.5.2 there, read at `08dfcb3` on both arches (§12).
- **Scope.** This PR regenerates the stale gallery `FakeBackend.qml`, which also pulls in
  FileShare's missing slots, and fixes the unknown-card fallback. The Nim backend's missing
  FileShare autopilot and FileShare's absence from `ui-parity.sh` are left for a separate PR.

Still open:
- **for the maintainer: `coordinate_proof` and the audio** (§10). A log proof carries every
  event's value whole, so a proof of a room with a note carries its Opus to the caller. Either
  the proof export is named as an exception to "audio plaintext never crosses IPC", or a new
  proof form carries voice parts as committed digests. Until then `coordinate_proof` refuses
  `voice-notes-present` for a room whose authentic view holds a part the fold stands, so a
  room with a voice note exports no proof at all. Since the review it no longer refuses for
  junk: an entry under `voice/` that is no note's part refuses nothing, and it leaves with
  the proof whole, so a copy of a note's bytes leaves too when this member's view holds none
  of that note's parts (§10). A note still refuses, whatever its state: complete, arriving,
  or broken, as two parts of a member's own, signed, whose clip fails its checks on purpose
  are (`voice_live_test` §26). The log is append-only, so any member can still switch a
  room's proof off for good, by sending one note. Junk can no longer do it; a note does,
  until this question is decided. A proof form that commits a part by digest would close
  both;
- **for the maintainer: a re-send path for a note the fleet half-delivered** (§8, §15).
  Delivery's send is fire-and-forget, so a part it lost is never seen, and nothing
  re-publishes a voice part: `coordinate_reannounce` re-sends intents only. Options: a voice
  part joins what `coordinate_reannounce` re-sends, or the module keeps a sent note's parts
  and re-sends a part no store query has returned;
- **which room holds the draft** (§8). A draft is refused as `room-changed` in any room but its
  own, and `voice_status` does not yet name that room. S8's draft surface therefore shows a
  draft in whichever room is open, and says so only when Send is refused (`room-changed`:
  "This recording belongs to another room. Send it from there, or discard it.");
- **for the maintainer: an older client in the room** (§10, "What still leaks", item 6). A
  member on a Muster from before voice notes (0.3.2 or earlier) serves every note's Opus to
  the modules loaded beside them, through `coordinate_graph` and `coordinate_proof`, and
  nothing in this PR can change that. Accept it as a stated gap (S10's registry entry), or
  keep voice notes out of a room until every member runs a version that strips them (nothing
  in the room says today which version a member runs);
- **for the maintainer: the version that carries voice notes.** This PR bumps no version:
  `module/metadata.json` and `ui/metadata.json` still read 0.3.2, the released
  `muster-v0.3.2`, and `RELEASING.md` step 1 bumps at release time. The registry gap and this
  doc draw the line by the feature, "a Muster from before voice notes", with "0.3.2 or
  earlier" as the releases of today. So the release that first carries voice notes should be
  numbered above every 0.3.x, 0.4.0 say, and a release cut from `main` before this PR merges
  moves "0.3.2" in the gap's body and here;
- **for the maintainer: the F-16 claim's last sentence.** The protects claim "A later joiner
  cannot read earlier messages" (`open-room`, the registry's first claim) ends "Removal
  rotates the epoch immediately." That is true of the key layer: `EpochCrypto.removeMember`
  (`epoch_crypto.nim:135`) rotates it, as `epoch_crypto_test.nim:61` shows, and
  `probe_epoch_removal_immediate` shows the same for the epoch model in `crypto/epochs.nim`.
  But no room path removes a member, which is the S10 gap "Leaving a room re-keys nothing" in
  the same step. Reword it (for example "The key layer rotates the epoch on removal; nothing in the
  room removes a member yet, the gap below"), or keep it. This PR leaves it as it is on
  `main`;
- whether to coarsen `voice_status`'s peak for co-resident callers (§13);
- the exact disclosure wording on the draft surface (§8);
- whether the gaps of §10 stay registry entries of their own, as S10 added them, or fold into
  existing ones.

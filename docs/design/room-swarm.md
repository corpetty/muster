# FileShare — the room swarm: a private file swarm on Logos Storage, with the room as its tracker

Status: **planned 2026-10-15. By 2026-10-16 S0, S2 and S3 are done, and FileShare runs end to
end in the real runner**: two instances share a file through `storage_module` on a private
storage network (`scripts/fileshare-self-test.sh`). Still open: the install remedy, the
view on a display and in Basecamp, and a file picker (§7). Epic `exo-4d0`: S0–S7 are `exo-4d0.1`–`.8` in the order of §7,
and the upstream asks are `exo-4d0.9`. `pb dep tree exo-4d0` shows live status.

## 1. Where this comes from

Asked what he wanted to see in Muster, Jarrad (Logos) said:

> I know Storage (Logos storage) was thinking of providing a simple storage peer network
> using delivery, because it offered a trusted bound, muster would actually be ideal for
> that, kinda like a mini private torrent tracker.

Muster has not used Logos Storage yet. F-17 has asked for it since the start ("artifacts …
content-addressed in Logos Storage, behind a storage interface"), and exo-dcc.14 (a room
outlives the fleet's store) needs somewhere durable to keep a room's log. This epic makes
Storage the first new platform stack Muster takes on since Monero, and makes it useful to
people on day one: **a room's members share files with each other, and seed them for each
other, and nobody outside the room can read them or tell what they are.**

## 2. The idea in one paragraph

A private BitTorrent tracker is three things: a membership list (who may take part), an
index (which files exist), and a peer list (who holds each one). The tracker is a server
that sees all three, and every member's IP besides. A Muster room already is the first
two, without a server: membership is the room's, epoch-keyed (invariant 7), and the room
log is an index nobody outside can read. So the room swarm adds the third, as log events,
and lets Logos Storage move the bytes. A member **shares** a file: Muster encrypts it
under a fresh key, uploads the ciphertext to their own storage node, and posts the CID and
the key into the room. Members who want it **fetch** it: Muster dials the storage peers
the room says hold it, downloads the ciphertext, decrypts it and checks it against the
digest the sharer committed. Anyone may then **seed** it, and says so in the room.
Storage moves opaque blobs; the room decides who can read them and who to ask for them.

## 3. What the platform gives us

`storage_module` 3.0.2 (atlas `stacks/storage.md`; source `logos-co/logos-storage-module`
@`7548f41`, engine `logos-storage/logos-storage-nim`). Bundled in Basecamp 0.3.2, in the
default catalogue, on all four platforms.

- **One node per host, shared.** In Basecamp the package downloader inits and starts it;
  `storage_ui` attaches to it. Config and data live in `~/.logos_storage/`, per OS user,
  not per Logos instance. A consumer must attach-or-create and **never stop or destroy a
  node it did not create**.
- **Upload** a file by path (`uploadUrl(path, chunkSize, advertise)`) and get a manifest
  CID from `storageUploadDone`. The manifest carries the **filename and mimetype in the
  clear**.
- **Download** by CID (`downloadManifest`, `downloadToUrl`, `downloadChunks`), with two
  flags: `isPrivate` tunnels the download and DHT lookups over Mix (KB/s), and `advertise`.
- **`advertise` is one bit for two things.** Read in `logos-storage-nim` @`d1f4f42`: when a
  dataset is not advertised, the node neither announces it to the DHT **nor answers for it**
  — `manifest/protocol.nim` returns NotFound and `blockexchange/engine/engine.nim` skips
  its presence in a peer's want-list. There is no "serve to these peers only".
- **A fetch goes through the DHT; a direct dial only helps it.** S0 observed this at
  runtime (`docs/labbook/storage-from-muster.md` Q1, Q4). The manifest is asked only of the
  providers the DHT lists for the CID; a peer the downloader has `connect`ed to is never
  asked unless the DHT names it. Two isolated nodes, connected, fail with "Key doesn't
  exist". A connection still earns its place: it makes a DHT-listed provider dialable when
  its announced address is not (the provider record carries only the public address, and
  a home router may not hairpin). On a private network bootstrapped from one node's SPR,
  10 MB moved in under a second; on `logos.dev`, 1.4–4.5 s, mostly the public DHT lookup.
  A fresh node takes about 2 minutes to become Reachable. Two members behind two home
  NATs: not yet tested.
- **Mix is slow.** A private fetch (`isPrivate`) worked on `logos.dev` at about 15 KB/s
  (1 MB in 71 s; 10 MB is about 11 minutes), and the two nodes never connected. It needs
  the preset's relay pool and DHT proxies; `storage_module` builds those only for the
  presets and turns Mix off for a custom network.
- **Events are host-wide.** Every subscriber sees every session's events (the
  downloader's, `storage_ui`'s); correlate by `sessionId` / `cid`. `fetch` has no
  completion event. `uploadChunk` declares its chunk as `tstr`; binary safety over IPC is
  unverified, so prefer `uploadUrl` with a file on disk.
- **Networks.** Presets `logos.test` (default) and `logos.dev`, or a private network from a
  first node's SPR (`no-bootstrap-node`). The storage network is independent of the
  delivery fleet Muster's room rides. **Basecamp 0.3.2's shared node is on `logos.test`
  with Mix on** (S0 Q8): the package downloader inits it as soon as `storage_module` is
  ready, and downloads packages with `advertise=false`, so it seeds nothing. `network()`
  names the default preset even on a private network, so it cannot place a node alone.

## 4. Private tracker, piece by piece

| | A private BitTorrent tracker | The room swarm |
|---|---|---|
| Who may take part | an account on the tracker's site | the room's members, admitted by a member, epoch-keyed |
| The index | the tracker's database, readable by its operator | `file/…` events in the room log, sealed to the room |
| Who holds what | the tracker's peer list, built from every client's announce: IP, port, infohash, bytes up and down | `seed/…` events, each signed by the member who seeds (invariant 9): their storage peer id and addresses |
| The secret | a passkey in every announce URL; it leaks with the `.torrent` | the room's epoch keys and a key per file; the file names no secret |
| Peer discovery | the tracker only; DHT and PEX off by the private flag | the storage DHT finds providers, and the room's seed events add a direct `connect` so a listed seeder can be dialled. Until asks 1 and 2 land, the DHT sees the ciphertext CID, its providers and each lookup (§3, §6) |
| What a stranger with the hash gets | the plaintext pieces, if they reach a peer | ciphertext; the key is only in the room |
| A late joiner | the whole catalogue | files shared from their epoch on; earlier ones only if a member shares them again (invariant 7) |
| Ratio | enforced by the tracker from self-reported stats | not enforced. Muster cannot see bytes served. Pledges (S7) are motivational and say so |
| The server | the tracker, a single point to seize or subpoena | none (invariant 8). The delivery store node and storage peers are untrusted infrastructure |

The education angle writes itself: every row of this table is a step the walkthrough can
show truthfully, with the observer who sees it.

## 5. The design

### 5.1 The storage seam (F-17)

`module/src/storage/` gets a seam in the shape of `Transport`:

- `BlobStore` — `put(path): Cid` (async), `get(cid, dest, private)` (async, with
  progress), `has(cid)`, `setServing(cid, on)`, `remove(cid)`, `reach(): PeerReach`
  (peer id, addresses, network), `connect(PeerReach)`.
- `LocalBlobStore` — a content-addressed directory, and a pair of them that serve each
  other in process. It is the stub every integration test uses ("never mock `Transport`"
  applies here too: tests run on the local store, not a mock).
- `LpStorage` — `storage_module` over `lp_*`, compiled only into the plugin (like
  `monero_backend_lp.nim`). It **attaches** to the shared node and never inits it in
  Basecamp: `init` rewrites `~/.logos_storage/config.json` for every consumer (S0 Q8).
  Events come through the `inbound_queue` seam, each a JSON document in `args[0]`. An
  upload is matched by its session id (a node-wide counter); a download's session id IS
  the CID, so downloads are matched by CID and other consumers' events on the same CID
  are expected (S0 Q7). The module thread never waits on storage (the cmPump / cmNow split
  `monero_backend_lp` uses).
- `storage_module` becomes an **optional** dependency of `muster_module`, graded by
  `module_registry` in three states, with Basecamp's `packages.install` as the remedy,
  exactly as `monero_wallet_backend` is (exo-dcc.10). The room works without it; the
  Files panel says what is missing.

### 5.2 Sealed blobs

`module/src/crypto/blob_seal.nim`, on the libsodium Muster already links:

- A fresh 32-byte key per file; `crypto_secretstream_xchacha20poly1305`, so a large file
  is sealed and opened in chunks without holding it in memory.
- The plaintext digest is a domain-separated hash-input record (`muster.blob.plaintext.v1`,
  invariant 5). After a download Muster opens the ciphertext and **refuses the file if the
  digest differs**, whatever the storage layer said about its own Merkle tree.
- The ciphertext is uploaded from a temp file with a **neutral name** (`<random>.bin`), so
  the storage manifest's cleartext filename and mimetype say nothing.
- Optional padding to a size bucket (Padmé), off by default, because ciphertext size is
  otherwise plaintext size plus a constant (a disclosure row says so).

### 5.3 The room is the tracker (log events)

All sealed to the room under the epoch key like every event; the author-bearing ones join
the `authorship.nim` list, so a forgery is dropped from the room's view (exo-f76).

| Key | Author-signed by | Body |
|---|---|---|
| `file/<fid>` | the sharer (`author`) | name, mime, size, plaintext digest, ciphertext CID, file key, seal scheme, storage network, `at` |
| `file/<fid>/seed/<who>` | `who` | `on` (seeding or stopped), storage peer id, addresses, network, `at` |
| `file/<fid>/retract` | the sharer only (`author`) | `at` — hides it from the list; it cannot unshare what members already hold, and says so |

`fid` is content-addressed over (sharer, CID) (`muster.swarm.file-id.v1`), so every member
derives it and nobody can post under another's file id. A seeder's newest announce wins by
(`at`, event id), the same on every member; a stop is an announce with `on: false`. `reduceSwarm(roomEvents(s))` folds them into
files and their seeders: order-free, idempotent (invariant 4), and a seeder appears only
because they announced (invariant 9). Muster never infers a holder from the storage node's
own peer table.

A late joiner (invariant 7) sees no `file/…` event from an earlier epoch, so they have
neither the CID nor the key. A member may share an earlier file again into the current
epoch; that is a new `file/…` event carrying the same CID and key, the member disclosing
what they legitimately hold. Removing a member re-keys forward but cannot take back keys
they already had; the panel says so.

Nothing here is signed for a chain, so invariants 1, 2 and 10 do not bind a plain share.
When a file is attached to an intent (an invoice on a split, §7 S8), its digest enters the
effect and F-20 classes it as an external read at its log position.

### 5.4 Fetching and seeding

1. Read the file's seeders from the fold. `connect` to each (the seed event's addresses),
   then `downloadToUrl` the ciphertext into the instance's temp directory. The download
   looks the CID up in the node's DHT: on Basecamp's shared node that is the public
   `logos.test` DHT, every time. The connection makes a seeder the DHT lists dialable
   when its announced address is not; it does not replace the lookup (§3).
2. Open it, check the digest, write the plaintext where the person chose. A mismatch is a
   refusal naming the sharer and the CID, never a partial file.
3. If the person keeps seeding (the default, §9), post `seed/<me>` and leave the dataset
   advertised. "Private fetch" (a per-file choice): `isPrivate=true`, `advertise=false`,
   no seed event — and **no direct dial in step 1**, because connecting to a seeder hands
   them this node's address. The fetch finds the blob through the storage network over
   Mix instead, and this member serves nothing afterwards (they can still choose to seed
   later). S0 saw this work on `logos.dev` at about 15 KB/s, so the panel says how long a
   private fetch will take before it starts, and it reaches only a seeder whose address
   is reachable.
4. A pump on the intents tick drives progress, retries other seeders, and re-announces
   when this node's addresses or reachability change. A seed event will say whether the
   node was Reachable when it was posted (with `LpStorage`, S1); an unreachable seeder serves only members
   connected to it.

### 5.5 Who sees what

Two new observer classes in `intents/disclosure.nim`, and the rows `flow.nim` shows:

| Observer | Sees | Never sees |
|---|---|---|
| room member | file name, size, sharer; each seeder by name with their storage peer id and **addresses (IP)** | — |
| store node (delivery) | that the room's topic carried an envelope, when, and its size (FS-9) | the file, its CID, who shared it |
| storage peer (new) | the peer id and IP of a node fetching or serving a ciphertext CID, and when | the plaintext, the name, the room |
| storage DHT (new) | the ciphertext CID and the set of peer ids providing it (while `advertise` is one bit) — so the seeders of one blob are linkable to each other, by peer id. A record outlives a stop until it expires, so the DHT keeps naming a past seeder. Each lookup tells the nodes asked that this peer wants this CID (a private fetch sends it through the preset's DHT proxies instead) | the plaintext, the name, the room, who in the room they are |
| mix node | with private fetch, a hop of a tunnelled download | the endpoints together |

The claims registry (ADR-012) gets the matching entries with credibility: content
confidentiality **imperative**; seeder IPs to room members and to storage peers
**exposed**; "only room members can fetch the ciphertext" a **gap** until asks 1 and 2 land.

## 6. Asks of the Storage team

The shareable version is `docs/design/storage-asks.md`, rewritten 2026-10-19 after Giuliano
(Storage lead) read the first one. His reading: **we want a permissioned tracker.** He was
right that "serve to named peers, fetch from named peers" (the first U1/U6) would wire the
overlay by hand and leave Muster doing peer selection and failure recovery. What we want is
our own peer **lookup** feeding Storage's swarm, which keeps sampling, scheduling and
recovery. The seam exists: `Discovery.find`/`provide` (`storage/discovery.nim`). It is
node-wide today, and the node also serves Basecamp's package downloader on the DHT.

1. **A peer lookup the consumer supplies, per dataset** (replaces U1 + U6): for a room's
   CIDs, `find` asks the room (the seeders who announced, as SPRs) and `provide` tells the
   room; the DHT never sees them.
2. **Serve without announcing:** `advertise` is one bit for both today, so a seeder that
   stays off the DHT serves no one. Admission (serve only to the room's peers) is optional
   defence in depth: with ask 1 nobody outside can look the CID up, and the blob is sealed.
3. **A node or namespace per consumer** (was U2), which also gives ask 1 its scope.
4. **Events addressed to their caller** (was U3).
5. **`fetch` completion; `uploadChunk` as `bstr`** (was U4).
6. **A manifest with no filename or mimetype** (was U5).

## 7. Order of work

Each slice's acceptance criteria become a test before its implementation (working
agreement). S3's spec goes through `discuss-issue` first.

- **S0 — Ground truth (done 2026-10-15; `docs/labbook/storage-from-muster.md`).** Two storage nodes on a private network and
  on `logos.dev`: does a directly connected seeder serve a fresh downloader with no DHT
  provider record, and how fast; does `isPrivate` work against a `connect`ed peer; what
  happens across two home NATs; what network the downloader inits the shared node on in
  Basecamp 0.3.2; does `uploadChunk` carry binary intact; can a Nim module subscribe to
  `storageUploadDone` over `lp_*`. Labbook `docs/labbook/storage-from-muster.md`.
- **S1 — The storage seam.** `BlobStore`, `LocalBlobStore`, `LpStorage`; optional
  dependency, three-state readiness, install remedy. *Landed 2026-10-16:* the seam, the
  stand-in, `LpStorage` (`storage_lp.nim` + the pure `storage_events.nim`), the optional
  dependency, and `storage_module` 3.0.2 in the runner (its contract handed to the UI builder
  without `importFiles`, which that builder's parser refuses). *Open:* readiness through
  `module_registry` and Basecamp's install remedy; today the tab only says what is missing.
- **S2 — Sealed blobs** (landed: `crypto/blob_seal.nim`, `blob_seal_test`). Round trip,
  tamper and truncation refusals; the check that an uploaded manifest names nothing moves
  to S1, which has a storage node. Padding is not built.
- **S3 — The room as tracker.** The three event kinds, `reduceSwarm`, authorship (landed: `coordination/swarm.nim`, `swarm_test`;
  spec `derived-exo-4d0.4` graded 5/5, with safe file names as its s5). Spec
  `derived-exo-4d0.4` with probes: the fold is order-free and idempotent; a seeder is listed
  only by their own signed announce; a forged announce is dropped; a later-epoch member
  holds no key to an earlier file; a digest mismatch refuses.
- **S4 — Hosted surface** (landed 2026-10-16). `muster.lidl`: `fileshare_status`,
  `fileshare_share`, `fileshare_files`, `fileshare_fetch`, `fileshare_seed`,
  `fileshare_retract`; one `SwarmNode` per room on the intents tick; the storage-peer and
  storage-dht observers. `swarm_live_test` over `LocalBlobStore`s and `LocalTransport`.
- **S5 — The FileShare tab.** In the room: share, the list (sharer, size, seeders by
  name), Fetch / Fetch privately / Seed / Remove from list, progress, a refusal; the
  who-sees-what box from §5.5. *Landed 2026-10-16:* the tab in the room details drawer (and
  the header menu), both backends' slots, and `scripts/fileshare-self-test.sh`: two runners
  offscreen on a private storage network, share → fetch byte-identical → seed, 3 of 3 runs
  green (~13 s). *Open:* a native file picker (a path field for now), a look on a display,
  a third instance fetching with the sharer gone (held in process by `swarm_live_test`
  only), and Basecamp 0.3.2 against its bundled node.
- **S6 — The lesson.** Walkthrough steps and claims-registry entries built from §4 and
  §5.5: what a private tracker's operator sees, what the room's infrastructure sees.
- **S7 — Pledges (decide after S5).** "Keep this available until T" as an intent with a
  no-chain driver (locus `each`): each pledger agrees with their room key; any member who
  holds the file can spot-check a pledger by asking for the hash of a random range. Graded
  motivational in the claims registry: Muster cannot make anyone keep bytes.
- **S8 — Later, each its own decision.** (a) Room log backup: members upload the room's
  sealed envelopes (already per-epoch ciphertext) as a dataset and keep its CID beside
  `joined_rooms`, so a room outlives the fleet's store (exo-dcc.14). (b) Files on cards:
  an invoice attached to a split, its digest in the effect, F-20's external read. (c) Asks 1
  and 2 adopted once Storage ships them: the DHT rows in §5.5 go away.

## 8. Invariants, checked

| # | How the swarm keeps it |
|---|---|
| 3 | No plugin involvement; the core seals and fetches. |
| 4 | Files and seeders are `reduceSwarm(log)`. Blobs are referenced by CID + key in the log; a local copy is a cache, rebuilt by fetching. |
| 5 | Every event body is dCBOR; the plaintext digest is a hash-input record. |
| 7 | File keys travel in events sealed to the epoch they were shared in. |
| 8 | Storage nodes, the DHT and Mix are untrusted infrastructure; no server of ours. |
| 9 | A seeder is named only by their own signed announce; the panel grades only your own holdings. |
| 10 | A plain share signs nothing for a chain; an attachment enters an effect as an external read (S8b). |

## 9. Decisions

Decided by the operator:

- **The name is FileShare** (2026-10-16). The code keeps *swarm* for the mechanism; the
  methods are `fileshare_*`.
- **Seeding after a fetch is on by default** (2026-10-15). A member can choose a private
  fetch instead (§5.4 step 3): over Mix, nothing served afterwards, no seed event.
- **Seed events carry the seeder's network addresses** for now (2026-10-15). Storage's own
  privacy features (Mix-routed serving, asks 1 and 2) come later and change the §5.5 rows when
  they do.

Still open:

- **Storage network**: whatever the shared node is on, recorded per share and per seed
  event so a mismatch is shown, not guessed (proposed until U2). `network()` alone cannot
  say (S0 Q8): a node on a private network answers the default preset. The seed event's
  SPR and addresses are what actually place a node.

# What Muster would ask of Logos Storage

**For:** the Logos Storage team (`logos-storage-nim`, `logos-storage-module`), through Corey and Jarrad.
**Status:** rewritten 2026-10-19 after Giuliano's reply (below). On Muster's side, FileShare (the room swarm) runs end to end in Muster's own app: two instances share a file through `storage_module` 3.0.2 (`scripts/fileshare-self-test.sh`, branch `feat/room-swarm`). It has not yet been tried in Basecamp.
**Reads with:** `docs/design/room-swarm.md` (the design), `docs/labbook/storage-from-muster.md` (the S0 spike, Q1–Q8, every command and result).

## The short version

Jarrad, asked what he wanted to see in Muster:

> I know Storage (Logos storage) was thinking of providing a simple storage peer network
> using delivery, because it offered a trusted bound, muster would actually be ideal for
> that, kinda like a mini private torrent tracker.

Giuliano read the first version of this page and put it more precisely: **we want a permissioned tracker.** The first version asked to "serve to named peers and fetch from named peers". As he pointed out, pinning peer lists wires the overlay by hand, and leaves Muster doing its own peer selection and failure recovery. We don't want that. Storage doing those is the reason to use Storage.

What we want instead is the split he described: **our own peer lookup, feeding your swarm.**

- **The room is the tracker.** It knows who may take part (the room's members), what exists (the files shared into the room), and who provides each file (each member's own signed "I seed this").
- **Storage is everything else:** sampling peers, dialing, block discovery and scheduling, failure recovery, transports, Mix.

Content is sealed per file before Storage sees it, so Storage only ever moves ciphertext.

The asks, roughly by how much they would help:

1. **A peer lookup the consumer supplies, per dataset.** `find` and `provide` for a room's datasets go to the room, not the DHT. Everything downstream of `find` stays yours.
2. **Serve without announcing.** Today `advertise=false` also refuses to serve, so a seeder that stays off the DHT serves no one.
3. **A node, or a namespace, per consumer.**
4. **Events addressed to their caller.**
5. **A `fetch` completion event, and `uploadChunk` as `bstr`.**
6. **A manifest with no filename or mimetype.**

Asks 1 and 2 are the ones that matter. Together they keep a room's files off the DHT entirely.

## The whole picture

| Layer | Who | What it does |
|---|---|---|
| Membership | the Muster room, over Logos Delivery | Who may take part. Admission is by a member; keys rotate per membership epoch, so a later joiner cannot read earlier entries |
| Index | the room's log | `file/<fid>`: name, size, plaintext digest, ciphertext CID, file key — sealed to the room |
| Peer records | the room's log | `file/<fid>/seed/<who>`: signed by the seeder, carrying how to reach their storage node; a seeder is listed only by their own announce |
| **Peer lookup** | **the room (ask 1)** | for a room's CID: the providers that announced in the room; Storage samples from them |
| Swarm, transfer, recovery | Storage | random subsets and swarm deltas, dialing, block exchange and scheduling, failures, bans, Mix |
| Bytes | Storage | sealed blobs, content-addressed and verified against the tree |

Muster takes on nothing in the "Storage" rows. If the room's lookup returns too few or dead providers, the swarm should behave as it does when the DHT returns too few or dead providers. Ask 1 only changes where `find` gets its answer.

## Where the seam already is

*Read in code, `logos-storage-nim` @`d1f4f42`.*

- `storage/discovery.nim` defines `Discovery` with base methods `find(cid, useMix)` (l. 130) and `provide(cid)` (l. 150), over `findDirect` and `findViaMix`.
- A node builds one `Discovery` (`storage/storage.nim:501`). Three places use it:
  - the manifest fetch (`manifest/protocol.nim:216`);
  - block discovery (`blockexchange/engine/discovery.nim:68`, which dials what `find` returns);
  - the advertiser (`blockexchange/engine/advertiser.nim:162`).
- Peer selection and failure handling live in the swarm (`blockexchange/engine/swarm.nim`): deltas 2/16/target 8 (l. 29–31), exploration 0.2 (l. 35), `recordPeerFailure` (l. 152), `banPeer` (l. 137).

So "replace the DHT with your own peer lookup" lands on one seam, with nothing below it changing. The one wrinkle is that the seam is node-wide today. The same node fetches Basecamp's packages through the DHT, so the room's lookup has to apply to the room's datasets only.

## What was run

All runs were on 2026-10-15/16, on one Linux host. Every node had its own scratch data dir.

| Piece | Version |
|---|---|
| Engine | `logos-storage-nim` v0.5.3 (release binary, REST API on) |
| Module | `storage_module` 3.0.2 (`logos-storage-module` @`7548f41`), under `logoscore` and in Muster's own app |
| Basecamp | 0.3.2, which pins the same module and engine |
| Code read | `logos-storage-nim` @`d1f4f42` (v0.5.3 plus four commits, none in the paths cited) |

Findings are graded **observed at runtime** or **read in code**, as the labbook grades them.

## What works today

- **A private network of the room's own nodes.** Every node bootstraps from one member's SPR. 10 MB arrived in 0.93 s and 100 MB in 10.5 s on loopback. *Observed* (Q1).
- **Muster end to end on such a network.** Two Muster instances, each with its own `storage_module` node: one shares a 3 MB file, the other fetches it byte-identical and seeds it, in about 13 s. *Observed*: `scripts/fileshare-self-test.sh`.
- **`logos.dev`.** 1.4–4.5 s for 10 MB, most of it the public DHT lookup. A fresh node took about 2 minutes to become Reachable. *Observed* (Q4).
- **Mix (`isPrivate`).** On `logos.dev` the manifest came in 7.0 s and 1 MB in 70.7 s (~15 KB/s); the two nodes never connected. *Observed* (Q3).
- **The serve gate holds.** With `advertise=false` a seeder answers NotFound for the manifest and sends no blocks. *Observed* (Q2).

## What Muster does on its side

So you can see what we are not asking for:

- **Sealed blobs.** Each file gets a fresh key (libsodium secretstream, 64 KiB chunks). After a download Muster checks the plaintext against the digest the sharer committed, and refuses the file on a mismatch.
- **A neutral upload name.** The ciphertext goes up as `<random hex>.bin`, so the manifest says only "an opaque blob of N bytes" (Q5).
- **The room as index and peer records.** These are signed, author-checked log events. Muster never infers a holder from what a node sees. A spec with five model-checked guarantees covers this (`derived-exo-4d0.4`).
- **Private fetch.** `isPrivate=true`, no direct dial, nothing announced.
- **Named observers.** Muster's disclosure table lists the storage DHT and the storage peers next to each shared file, with what each can see.
- **Never your config.** Where Muster has to start a node itself (its own app, beside Basecamp), it uses its own data dir and port. It also puts `~/.logos_storage/config.json` back exactly as it was. We learned this the hard way: a second node on `~/.logos_storage/data` fails with "Should create metadata store!".

## The asks

Each gives what we'd want, why, what Muster does without it, and a possible shape. The shapes are suggestions; you know the engine.

### 1. A peer lookup the consumer supplies, per dataset

**What we'd want.** For datasets the consumer names, `find(cid)` gets its providers from the consumer instead of the DHT, and `provide(cid)` tells the consumer instead of the DHT. Storage keeps sampling, dialing, scheduling and recovering exactly as it does for DHT providers. Every other dataset on the node stays on the DHT.

**Why.** *Observed* (Q1): two nodes, connected but on separate DHTs, cannot fetch from each other. The manifest is asked only of providers that `find` returns (`manifest/protocol.nim:216`). So today the only way for a room's members to find each other is a DHT they share.

**Without it.** Every fetch of a room's file is a lookup on the public DHT (`logos.test` on Basecamp's node). Every seeder's provider record is public. The DHT therefore sees each sealed blob's CID, every peer that provides it, and every peer that asks for it. It cannot read the blobs, but it can link the room's members to each other by blob. Muster's design names this as the gap ask 1 closes (`room-swarm.md` §5.5).

**A possible shape.** A per-dataset (or per-namespace, see ask 3) provider source, for example:
- `setProviderSource(cid, consumer)` once;
- an event `storagePeersWanted {cid, transport}` that the consumer answers with `providers(cid, [spr])`;
- `storageProvide {cid}` in place of the DHT announce.

Or: `downloadToUrl(…, providers: [spr])` together with `uploadUrl(…, announce: false)`, with `find` consulting the providers a download was given before (or instead of) the DHT. Either way the swarm samples from what it is given. Muster would hand over SPRs; its signed seed events carry a peer id and addresses today, and would carry the SPR instead.

### 2. Serve without announcing

**What we'd want.** Announcing to the DHT and serving as separate switches.

**Why.** `advertise` is one bit for both. *Read in code:* `handleManifestRequest` returns NotFound for a dataset that is not advertised (`manifest/protocol.nim:126`), and the block engine skips presence (`engine.nim:1021`) and block requests (`:1227`). *Observed* (Q2): after `advertise=false`, a peer that had the provider record got "Manifest not found on peer", and a stream sat at 0 bytes for 90 s.

**Without it.** Ask 1 cannot work. A seeder that stays off the DHT serves no one.

**Admission is optional.** Should a node serve a dataset only to the peers its provider source names? With ask 1 the room's CIDs never reach the DHT, so a stranger has nothing to look up, and the content is sealed anyway. We'd take it as defence in depth, not as a requirement.

### 3. A node, or a namespace, per consumer

**Why.** In Basecamp 0.3.2 the package downloader inits the shared node on `logos.test` with Mix on (*read in code*, Q8). `init` rewrites `~/.logos_storage/config.json` for everyone (*observed*). `network()` names the default preset even on a private network (*observed*). Ask 1 also needs a scope: the room's datasets on a lookup of their own, beside the downloader's datasets on the DHT. A namespace would be that scope.

**Without it.** Muster attaches to Basecamp's node and takes whatever network and Mix settings it has. In its own app it runs a separate node, at a data dir and port of its own, and restores the shared config file.

**A possible shape.** `init(config, namespace)` with its own data, settings and provider source per namespace, never writing the shared file. And `network()` that says `"custom"` (or names the bootstrap set) off the presets.

### 4. Events addressed to their caller

**Why.** Events are host-wide. A download's session id is its CID (*observed*, Q7), so two consumers fetching one CID share one event stream.

**Without it.** Muster matches downloads by CID. It treats a "done" without a file at its own destination as not its own.

**A possible shape.** A per-call session id for downloads, as uploads have, or a `caller` field on every event.

### 5. A `fetch` completion event, and `uploadChunk` as `bstr`

**Why.** The contract says `fetch` emits nothing when it completes. `uploadChunk` takes a `tstr`, and non-UTF-8 bytes have no JSON-string form (*read in code*, Q6).

**Without it.** Muster uploads from a temp file with `uploadUrl`, and does not use `fetch`.

### 6. A manifest with no filename or mimetype

**Why.** The manifest carries the uploaded file's name and a mimetype guessed from its extension to every peer that fetches it (*observed*, Q5).

**Without it.** Muster seals to a temp file anyway and names it `<random>.bin`, so this costs Muster little. A consumer uploading a file as-is has no such workaround.

## Smaller things we hit

- **A Mix sender in its own pool fails** ("can't dial self", 126 times; *observed*, Q3).
- **Mix on a custom network is off**, and needs a hand-built pool (*read in code*).
- **`-b <spr>` fails to parse;** `--bootstrap-node=<spr>` works (*observed*).
- **A provider record carries only the public address,** so two nodes behind one router that does not hairpin cannot use it (*observed*, Q4).

## What we can offer

- **A consumer for ask 1.** The room already produces signed, membership-scoped provider records. It can answer `find` for its datasets the day a seam exists, and we would test a branch against Muster's self-tests.
- **A second consumer** beside the package downloader, to shape asks 3 and 4.

## Open questions for you

1. **Is a consumer-supplied provider source per dataset or namespace something you'd take?** Or would you rather it look different, for example a tracker protocol the node speaks itself?
2. **What does the swarm need from a lookup to behave well?** How many providers per `find`, how fresh, how often re-asked, and what should a source do when it has fewer than `deltaMin`?
3. **How do provider records expire,** and can a provider withdraw one? (A seeder that stops is still named by the DHT until the record expires.)
4. **Two members behind two home NATs.** Is circuit relay (`--nat-max-relays`) the intended path, and does it carry a block exchange at a useful speed?
5. **Was "a simple storage peer network using delivery" meant to look like this?**

# module/src/storage/

The storage seam (F-17), for the room swarm (epic exo-4d0, `docs/design/room-swarm.md`).
Muster codes against `BlobStore`, never against `storage_module`.

- `blob_store.nim`: the `BlobStore` seam and `LocalBlobStore`, the in-process stand-in every
  integration test runs on (never a mock). It behaves as `storage_module` 3.0.2 does where
  the swarm depends on it: one bit for served-and-announced, connected peers then the DHT,
  a private download hides the fetcher. It records what a server and the DHT observed, so
  disclosure rows can be checked against it.
- `storage_lp.nim`: `LpStorage`, the `BlobStore` seam over `storage_module` through `lp_*`
  (exo-4d0.2), compiled only into the plugin. It attaches to the host's node; where it must
  start one, it keeps it to this instance and puts the shared config back.
- `storage_events.nim`: the pure half of that binding: reading `storage_module`'s replies and
  events, and keeping Muster's jobs. No `lp_*`, so it is unit-tested directly.
- `storage_readiness.nim`: FileShare's readiness. It asks the host's registry first (not
  installed names the package), and the node only once the host says the module is ready.

Rules:
- Bytes here are opaque. The swarm seals a file before it is uploaded
  (`crypto/blob_seal.nim`); nothing in this directory sees a key or a plaintext.
- The host's storage node is shared (the package downloader starts it). Attach to it;
  never stop or destroy a node Muster did not create.
- Every call that waits on the network is a job read after `poll`; the module thread
  never waits on storage.
- Where `LocalBlobStore` and the platform differ, the platform wins: fix the stand-in, and
  record the finding in `docs/labbook/storage-from-muster.md`.

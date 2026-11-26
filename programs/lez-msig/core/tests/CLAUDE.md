# programs/lez-msig/core/tests/

One test per rule of the design's §5, plus property tests for R.1 (an action runs iff the APPROVE
weight reaches the threshold) and the nonce window. The tests are append-only: extend them, never
weaken them. RFP S.7's minimums are here: below threshold, R.2, and nothing before create.

`rotation.rs`: D19 (design §7, "D19 in detail"): an approved `Rotate` retires the multisig and hands
its configuration to a successor; a retired multisig refuses all but `Sweep`; `adopt` writes a
handover once; the successor runs under the new configuration and the removed member cannot spend;
a queued rotation cancels the rest of the queue; limit usage and nonces carry over; v0.3's `apply`
refuses rotation. `muster_vectors_unchanged` holds every pre-D19 byte Muster's port is held to.

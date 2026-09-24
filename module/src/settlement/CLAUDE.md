# module/src/settlement/

The settlement seam (exo-a50.1.5; seam S6 of `docs/design/multisig-landscape.md`).
A multisig family is scheme × settlement: the driver says what a contribution is and
verifies it; the SETTLEMENT turns an executable intent's contributions into a chain
transaction and carries it through the `ChainAdapter` seam (`module/src/wallet/`).

- `settlement.nim` — `Settlement` (assemble / submit / watch) and `settlementFor`,
  which picks one from the driver's family PROFILE — never a policy string, never a
  concrete-type branch in the core. `SafeSettlement` is the first tenant: it
  re-derives the safeTxHash, admits only contributions the driver accepts (dedup by
  recovered owner, ascending order, threshold enforced), builds the real ten-argument
  `execTransaction`, and submits from a configured relayer through the adapter.

Rules: a family with `settlement: none` (room families) or an undeclared/unsupported
driver has NO settlement (nil) — never a guessed one. Assemble never trusts a
signature the driver would reject. A failed chain read or submit surfaces as an error,
never a false "landed" (R-8).

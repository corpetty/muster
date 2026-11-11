# quest_program/src/

`plan` and `apply` (lib.rs) and their in-process tests (tests.rs). Plan checks who signed and which
rows a bounty moves, with no data; apply checks the effect's claim against the record. Every rule
is an assertion whose message a test names. See ../../CLAUDE.md.

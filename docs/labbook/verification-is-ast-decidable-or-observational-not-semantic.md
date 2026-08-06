# Verification is AST-decidable or observational, not semantic

A working note on why "does this satisfy the requirement?" almost always
reduces to a mechanical check, rather than staying an open-ended judgment
call. Referenced from
[`../../.claude/doctrine/testing.md`](../../.claude/doctrine/testing.md) and
[`../test-validity.md`](../test-validity.md).

## The claim

Most things that feel like they need a human (or an LLM) to "just judge" them
actually decompose into one of two mechanical forms:

- **Structural** — the verdict is decided by the presence or shape of text:
  does this symbol exist, does this file exist, does this doc cite its
  source. Checkable by parsing (grep, an AST walk, a schema validator).
- **Observational** — the verdict is decided by *observed runtime behavior*
  over a real execution: does the process exit 0, does the output match, does
  the state change the way it should. Checkable by running the thing and
  looking at what happened.

What's left over — genuine semantic judgment about intent, not just form — is
a real residue, but it is smaller than it looks, and it is a backlog to keep
shrinking (find the AST shape or the observable behavior that reflects the
intent), not a permanent shrug.

## Why this matters for testing

Every test in this repo should be classifiable as one or the other of these
two forms. If you find yourself writing a test whose "assertion" is really "a
human should read this and judge whether it's good," that is a signal the
check belongs in a different process (a review checklist), not in the
automated suite pretending to grade something it cannot.

## Practical corollary

When authoring an acceptance check, ask: is this claim about the *shape of
an artifact* (structural), or about *what happens when it runs*
(observational)? Naming which one you're writing prevents the two most common
failure modes: using a structural check (grep) to stand in for a behavioral
claim it cannot actually verify, and writing an observational check that
never gets run against a real execution.

#!/usr/bin/env bash
# tdd-trailer commit-msg enforcement hook (pebble exo-8d1.4).
#
# Installed by `exophial init` (ansible/init.yml) into every provisioned
# repo at scripts/git-hooks/tdd-trailer.sh and wired as a `local`/
# `commit-msg`-stage pre-commit hook (.pre-commit-config.yaml.j2). Rejects
# any commit whose message carries neither a "Tested-Behavior:" nor a
# "TDD-Exempt:" trailer, so the testing-doctrine trailer convention is
# mechanically enforced rather than merely documented (the Treadset gap,
# 2026-07-09: the taxonomy was written in testing.md but nothing required
# the trailer on an actual commit).
#
# pre-commit invokes a commit-msg-stage hook with the path to the file
# holding the commit message as $1 -- the same argument git's own native
# commit-msg hook receives.
set -euo pipefail

msg_file="$1"

if grep -qE '^(Tested-Behavior|TDD-Exempt):' "$msg_file"; then
  exit 0
fi

cat >&2 <<'EOF'
commit rejected: message must carry a 'Tested-Behavior:' or 'TDD-Exempt:' trailer.

  Tested-Behavior: <what test now covers the behavior this commit adds>
  TDD-Exempt: <why this commit has no behavior to test (docs, refactor, ...)>
EOF
exit 1

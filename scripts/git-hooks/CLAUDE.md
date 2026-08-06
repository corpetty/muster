# scripts/git-hooks/

Enforcement hook scripts `exophial init` installs into this repo, wired as
local pre-commit hooks by the templated `.pre-commit-config.yaml`. Installed
verbatim (`ansible.builtin.copy`, canonical fix always propagates) rather than
templated — this is enforcement infrastructure, not human-editable policy.

- `tdd-trailer.sh` — git commit-msg enforcement hook (pebble exo-8d1.4):
  rejects a commit whose message carries neither a `Tested-Behavior:` nor a
  `TDD-Exempt:` trailer.

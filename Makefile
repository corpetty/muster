# Muster — run the real client (module/ + ui/).
#
# `make run` launches the STANDALONE app: logos-standalone-app hosting the muster
# UI + muster_module directly, no logos-basecamp and no package manager. Verified
# 2026-08-24 to render the dashboard and the six-step walkthrough offscreen.
#
# Prefer basecamp? See ui/tests/README.md § "Producing the app-under-test".
#
# A fresh clone builds: every flake input is a GitHub ref. module/flake.nix pins
# logos-module-builder to the corpetty fork (the nim.packages hook + a RUNPATH fix,
# upstream-pending in logos-co/logos-module-builder#226), and ui/flake.nix reaches
# muster_module inside the clone (`build` below overrides it to this clone's absolute
# path at build time). Tests: module/tests/run-suite.sh (module/tests/README.md).

UI       := ui
# The private lez-msig's provers in the runner (exo-cc7): lez_msig_module (programs/lez-msig) for
# a LEZ v0.3 zone and lez_msig_v04_module (programs/lez-msig/lez04) for a v0.4 one, side by side;
# muster_module calls the one its zone needs.
RUN_DIR  ?= $(CURDIR)/.run/muster

# cache.nix.logos.co as a substituter (the invoking user is not a trusted nix
# user, so pass it explicitly); --accept-flake-config takes the flake's own.
CACHE := --accept-flake-config \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=

# A runner build's flake evaluation alone took 7.4 GB on 2026-10-05 and OOM-froze a
# workstation (.claude/doctrine/codebase.md § Runner builds). Builds are uncapped by
# default. On a machine short of memory, set BUILD_MEM (e.g. `export BUILD_MEM=10G` in
# your shell profile, or `make build BUILD_MEM=10G`): `build`, `build-lgx` and `appimage`
# then run their nix calls in a user cgroup scope capped at it, so only the build dies if
# it runs over. The scope holds the evaluating nix client; derivations still build under
# nix-daemon, outside it.
BUILD_MEM      ?=
CAPPED          = $(if $(BUILD_MEM),systemd-run --user --scope --quiet -p MemoryMax=$(BUILD_MEM) -p MemorySwapMax=0 nice -n 19)
# A capped recipe opens with CAP_CHECK, which refuses to start when the cap can't be
# applied (never a silent fallback to uncapped), and its build line ends `|| $(CAP_KILLED)`,
# which says so when the cap killed it (137) and keeps the exit status either way.
CAP_CHECK       = [ -z "$(BUILD_MEM)" ] || $(CAPPED) true \
  || { echo "make $@: cannot cap memory at BUILD_MEM=$(BUILD_MEM) with systemd-run --user; unset BUILD_MEM to build uncapped"; exit 1; }
CAP_KILLED      = { s=$$?; [ $$s -ne 137 ] || echo "make $@: killed at the BUILD_MEM=$(BUILD_MEM) cap. Free memory, or build when the host is quieter; raise BUILD_MEM only if the host can spare it"; exit $$s; }
CAP_NOTE        = $(if $(BUILD_MEM),memory-capped at BUILD_MEM=$(BUILD_MEM),uncapped; BUILD_MEM=<size> caps it)

FLEET     ?= logos.dev
FLEET_CFG := infra/fleets/$(FLEET).json

# dev/demo owner seeding (exo-001). These are the *well-known* anvil dev keys —
# never real funds. Seeding a peer with an anvil Safe owner key makes its in-app
# approval recover to a real on-chain owner, so a 2-of-3 Safe intent settles on
# chain from in-app Approve. run-fleet auto-maps alice→owner0, bob→owner1; any
# other PEER is unseeded (random identity) unless you pass SEED=0x…. Honoured only
# when minting a fresh identity — `make clean-peer PEER=<x>` first to re-seed.
ANVIL_KEY0 := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_KEY1 := 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
SEED      ?=

.PHONY: help run run-fleet build build-nim build-lgx appimage clean clean-peer

# Which UI build run / run-fleet launch, as the self-tests choose it (scripts/lib/ui-build.sh):
# cpp (default) the C++ backend in the standalone runner; nim the Nim UI on seaqt
# (exo-607, ADR-019), after `make build-nim`. Both take the same --user-dir and environment.
MUSTER_UI ?= cpp
LAUNCH_cpp = cd $(UI) &&
LAUNCH_nim =
RUNNER_cpp = nix run 'path:.' $(CACHE) --
RUNNER_nim = $(CURDIR)/.run/runner-nim/bin/muster-ui
LAUNCH = $(LAUNCH_$(MUSTER_UI))
RUNNER = $(RUNNER_$(MUSTER_UI))

help:
	@echo "make run                 launch the standalone muster app (dashboard + walkthrough)"
	@echo "make run-fleet PEER=x     launch a peer on the Logos delivery fleet (two-instance)"
	@echo "make build               pre-build the runner — the slow first build; do this once ($(CAP_NOTE))"
	@echo "make build-nim           build the Nim UI's runner (.run/runner-nim) on the runner's modules; then MUSTER_UI=nim make run"
	@echo "make build-lgx           build muster-ui.lgx (to load into logos-basecamp instead; $(CAP_NOTE))"
	@echo "make appimage            Basecamp's release AppImage with Muster baked in, from the committed tree (RELEASING.md; $(CAP_NOTE))"
	@echo "make clean               remove local run state (.run/)"
	@echo "make clean-peer PEER=x   wipe one peer's identity+wallet (to re-seed owner keys)"
	@echo ""
	@echo "First time: 'make build' (minutes), then 'make run'."
	@echo "Two-instance over the fleet: 'make run-fleet PEER=alice' and 'make run-fleet PEER=bob'"
	@echo "  in two terminals (FLEET=logos.dev|logos.test — logos.test needs an RLN membership since Testnet v0.3; refresh with infra/fleets/refresh.sh)."
	@echo "  alice/bob auto-seed as anvil Safe owners 0/1 so in-app Approve can settle on-chain."
	@echo "Basecamp option: ui/tests/README.md."

# Pre-build the runner so the first 'make run' doesn't stall building it while a
# window is expected. path:. picks up local ui/ edits; the runner GC-root lives
# under .run/ so 'make clean' keeps it (delete .run/runner to release it).
build:
	@mkdir -p $(CURDIR)/.run
	@$(CAP_CHECK)
	@# ui/flake.lock is machine-local + gitignored. muster_module is pinned in ui/flake.nix
	@# by a RELATIVE ref (git+file:../?dir=module, portable across clones, exo-1ec.2/#116) —
	@# but nix re-fetches a relative git input at eval time ("file:../ not supported"), and
	@# that fetch + the eval cache can go stale between a relock and the build, so `make build`
	@# would leave .run/runner pointing at an OLD runner even after a successful relock (exo-fb7).
	@# Fix: build with muster_module OVERRIDDEN to an ABSOLUTE git+file path derived from
	@# $(CURDIR) at build time (portable — it is wherever THIS clone is, never hardcoded) and
	@# with the eval cache off, so the runner is a deterministic function of the committed tree.
	@# The relock still runs first to keep ui/flake.lock current for a direct `nix build`, and
	@# to surface the dirty-tree WARN (a git+file input cannot lock from uncommitted state —
	@# commit first, or the build uses the last COMMITTED tree).
	@cd $(UI) && $(CAPPED) nix flake update muster_module lez_msig_module lez_msig_v04_module $(CACHE) 2>&1 | grep -q "not writing lock file" \
	  && echo "WARN: muster_module NOT relocked (uncommitted changes in the git tree) — the runner builds the last COMMITTED module rev; commit first to pick up module edits" || true
	cd $(UI) && $(CAPPED) nix build 'path:.#runner' $(CACHE) --no-eval-cache \
	  --override-input muster_module "git+file://$(CURDIR)?dir=module" \
	  --override-input lez_msig_module "git+file://$(CURDIR)?dir=programs/lez-msig" \
	  --override-input lez_msig_v04_module "git+file://$(CURDIR)?dir=programs/lez-msig/lez04" \
	  --out-link $(CURDIR)/.run/runner \
	  || $(CAP_KILLED)

# The Nim UI's runner (exo-607 T6): ui-nim#muster-app on the C++ runner's modules, so
# it needs `make build` first. Small and separate from the runner's flake.
build-nim:
	scripts/build-runner-nim.sh

# nix run resolves apps.default (the standalone runner), NOT packages.default
# (the .lgx). Each --user-dir is one identity + wallet, so two dirs are two peers.
# Seed this instance as anvil Safe owner 0 (like run-fleet does for alice), so YOUR
# own in-app Approve / Attest actually counts solo — otherwise a freshly minted
# identity isn't a Safe owner and every secp-policy signature is silently rejected.
# Honoured only on a FRESH identity: `make clean` (or clean-peer PEER=muster) once to
# adopt the owner key if you've already launched. Override with SEED= to opt out.
# (A target-specific `run: SEED ?= …` never applied: the global `SEED ?=` above has
# already defined it, empty. So decide by where SEED came from: given on the command
# line or in the environment — even empty — it wins; otherwise owner 0.)
RUN_SEED = $(if $(filter command line environment,$(origin SEED)),$(SEED),$(ANVIL_KEY0))
run:
	@mkdir -p $(RUN_DIR)
	@echo "launching muster (standalone) with user-dir $(RUN_DIR)"
	@[ -n "$(RUN_SEED)" ] && echo "  seeding as anvil Safe owner 0 (in-app Approve/Attest counts; 'make clean' to re-mint)" || true
	$(LAUNCH) MUSTER_DEV_SECP_KEY="$(RUN_SEED)" $(RUNNER) --user-dir $(RUN_DIR)

# Launch one peer already pointed at the Logos delivery fleet, so its transport
# joins a network with real bootstrap peers (the bundled preset ships none — see
# infra/fleets/README.md). MUSTER_DELIVERY_CONFIG seeds the delivery createNode
# config every muster instance in this process boots with (invariant 8 — the user
# can still override it in Settings). Run twice with distinct PEER for a two-
# instance live run: `make run-fleet PEER=alice` and `make run-fleet PEER=bob`.
# Each PEER is its own identity + wallet under .run/, i.e. a separate participant.
run-fleet: PEER ?= alice
run-fleet:
	@mkdir -p $(CURDIR)/.run/$(PEER)
	@test -f $(FLEET_CFG) || { echo "missing $(FLEET_CFG) — run infra/fleets/refresh.sh"; exit 1; }
	@echo "launching muster peer '$(PEER)' on fleet '$(FLEET)' (user-dir .run/$(PEER))"
	SEED_VAL="$(SEED)"; \
	if [ -z "$$SEED_VAL" ]; then case "$(PEER)" in \
	  alice) SEED_VAL=$(ANVIL_KEY0) ;; \
	  bob)   SEED_VAL=$(ANVIL_KEY1) ;; \
	esac; fi; \
	[ -n "$$SEED_VAL" ] && echo "  seeding '$(PEER)' as an anvil Safe owner (in-app Approve can settle on-chain)"; \
	$(LAUNCH) MUSTER_DELIVERY_CONFIG="$$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delivery_createNode_config"]))' $(CURDIR)/$(FLEET_CFG))" \
	  MUSTER_DEV_SECP_KEY="$$SEED_VAL" \
	  $(RUNNER) --user-dir $(CURDIR)/.run/$(PEER)

build-lgx:
	@$(CAP_CHECK)
	cd $(UI) && $(CAPPED) nix build 'path:.#lgx' $(CACHE) || $(CAP_KILLED)

# The download-and-run release artifact: Basecamp's released AppImage with Muster and its
# Logos Official dependencies installed inside, repacked (scripts/release-appimage.sh,
# RELEASING.md). No Basecamp checkout needed.
appimage:
	@$(CAP_CHECK)
	$(CAPPED) scripts/release-appimage.sh || $(CAP_KILLED)

clean:
	rm -rf $(CURDIR)/.run
	@echo "removed .run/ — next launch mints a fresh identity and wallet"

# Wipe ONE peer's identity + wallet so the next launch mints (and re-seeds) it.
# Needed to re-seed owner keys, since seeding is honoured only on a fresh identity.
clean-peer:
	@test -n "$(PEER)" || { echo "usage: make clean-peer PEER=<name>"; exit 1; }
	rm -rf $(CURDIR)/.run/$(PEER)
	@echo "removed .run/$(PEER) — next launch mints a fresh identity (re-seeds if PEER is alice/bob)"

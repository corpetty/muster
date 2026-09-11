# Muster — run the real client (module/ + ui/).
#
# `make run` launches the STANDALONE app: logos-standalone-app hosting the muster
# UI + muster_module directly, no logos-basecamp and no package manager. Verified
# 2026-08-24 to render the dashboard and the six-step walkthrough offscreen.
#
# Prefer basecamp? See ui/tests/README.md § "Producing the app-under-test".
#
# PORTABILITY CAVEAT — builds on THIS machine only, for now. ui/flake.nix pins
# muster_module by an absolute git+file path, and the muster build needs local
# logos-module-builder fork commits (the nim.packages hook + a RUNPATH fix) that
# are not upstream yet. Until those land, other people run it from a prebuilt
# release, not from a clone. Tracked in ADR-013/ADR-014.

UI       := ui
RUN_DIR  ?= $(CURDIR)/.run/muster
# Local logos-basecamp checkout (with the muster bake-in) — for `make appimage`.
BASECAMP ?= $(HOME)/Github/logos-co/logos-basecamp

# cache.nix.logos.co as a substituter (the invoking user is not a trusted nix
# user, so pass it explicitly); --accept-flake-config takes the flake's own.
CACHE := --accept-flake-config \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=

FLEET     ?= logos.test
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

.PHONY: help run run-fleet build build-lgx appimage clean clean-peer

help:
	@echo "make run                 launch the standalone muster app (dashboard + walkthrough)"
	@echo "make run-fleet PEER=x     launch a peer on the Logos delivery fleet (two-instance)"
	@echo "make build               pre-build the runner — the slow first build; do this once"
	@echo "make build-lgx           build muster-ui.lgx (to load into logos-basecamp instead)"
	@echo "make appimage            build the download-and-run AppImage (see RELEASING.md)"
	@echo "make clean               remove local run state (.run/)"
	@echo "make clean-peer PEER=x   wipe one peer's identity+wallet (to re-seed owner keys)"
	@echo ""
	@echo "First time: 'make build' (minutes), then 'make run'."
	@echo "Two-instance over the fleet: 'make run-fleet PEER=alice' and 'make run-fleet PEER=bob'"
	@echo "  in two terminals (FLEET=logos.test|logos.dev; refresh with infra/fleets/refresh.sh)."
	@echo "  alice/bob auto-seed as anvil Safe owners 0/1 so in-app Approve can settle on-chain."
	@echo "Basecamp option: ui/tests/README.md."

# Pre-build the runner so the first 'make run' doesn't stall building it while a
# window is expected. path:. picks up local ui/ edits; the runner GC-root lives
# under .run/ so 'make clean' keeps it (delete .run/runner to release it).
build:
	@mkdir -p $(CURDIR)/.run
	@# ui/flake.lock is machine-local + gitignored (it pins muster_module by absolute
	@# path), so a lock from an earlier session goes stale as the module evolves and
	@# `make run` silently launches an OLD build. Relock the local muster_module to the
	@# repo's current state first, so `make run` always reflects your module edits.
	cd $(UI) && nix flake update muster_module $(CACHE) 2>/dev/null || true
	cd $(UI) && nix build 'path:.#runner' $(CACHE) --out-link $(CURDIR)/.run/runner

# nix run resolves apps.default (the standalone runner), NOT packages.default
# (the .lgx). Each --user-dir is one identity + wallet, so two dirs are two peers.
run:
	@mkdir -p $(RUN_DIR)
	@echo "launching muster (standalone) with user-dir $(RUN_DIR)"
	cd $(UI) && nix run 'path:.' $(CACHE) -- --user-dir $(RUN_DIR)

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
	cd $(UI) && MUSTER_DELIVERY_CONFIG="$$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delivery_createNode_config"]))' $(CURDIR)/$(FLEET_CFG))" \
	  MUSTER_DEV_SECP_KEY="$$SEED_VAL" \
	  nix run 'path:.' $(CACHE) -- --user-dir $(CURDIR)/.run/$(PEER)

build-lgx:
	cd $(UI) && nix build 'path:.#lgx' $(CACHE)

# The download-and-run release artifact: a logos-basecamp AppImage with muster
# baked in. Needs the local basecamp bake-in (ui/tests/README.md); see RELEASING.md.
appimage:
	nix build '$(BASECAMP)#bin-appimage' $(CACHE) --out-link $(CURDIR)/result-appimage
	@echo "AppImage: $(CURDIR)/result-appimage/logos-basecamp.AppImage"
	@echo "Run: APPIMAGE_EXTRACT_AND_RUN=1 $(CURDIR)/result-appimage/logos-basecamp.AppImage  (then click Muster)"

clean:
	rm -rf $(CURDIR)/.run
	@echo "removed .run/ — next launch mints a fresh identity and wallet"

# Wipe ONE peer's identity + wallet so the next launch mints (and re-seeds) it.
# Needed to re-seed owner keys, since seeding is honoured only on a fresh identity.
clean-peer:
	@test -n "$(PEER)" || { echo "usage: make clean-peer PEER=<name>"; exit 1; }
	rm -rf $(CURDIR)/.run/$(PEER)
	@echo "removed .run/$(PEER) — next launch mints a fresh identity (re-seeds if PEER is alice/bob)"

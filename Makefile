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

.PHONY: help run run-fleet build build-lgx appimage clean

help:
	@echo "make run                 launch the standalone muster app (dashboard + walkthrough)"
	@echo "make run-fleet PEER=x     launch a peer on the Logos delivery fleet (two-instance)"
	@echo "make build               pre-build the runner — the slow first build; do this once"
	@echo "make build-lgx           build muster-ui.lgx (to load into logos-basecamp instead)"
	@echo "make appimage            build the download-and-run AppImage (see RELEASING.md)"
	@echo "make clean               remove local run state (.run/)"
	@echo ""
	@echo "First time: 'make build' (minutes), then 'make run'."
	@echo "Two-instance over the fleet: 'make run-fleet PEER=alice' and 'make run-fleet PEER=bob'"
	@echo "  in two terminals (FLEET=logos.test|logos.dev; refresh with infra/fleets/refresh.sh)."
	@echo "Basecamp option: ui/tests/README.md."

# Pre-build the runner so the first 'make run' doesn't stall building it while a
# window is expected. path:. picks up local ui/ edits; the runner GC-root lives
# under .run/ so 'make clean' keeps it (delete .run/runner to release it).
build:
	@mkdir -p $(CURDIR)/.run
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
	cd $(UI) && MUSTER_DELIVERY_CONFIG="$$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delivery_createNode_config"]))' $(CURDIR)/$(FLEET_CFG))" \
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

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

UI      := ui
RUN_DIR ?= $(CURDIR)/.run/muster

# cache.nix.logos.co as a substituter (the invoking user is not a trusted nix
# user, so pass it explicitly); --accept-flake-config takes the flake's own.
CACHE := --accept-flake-config \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=

.PHONY: help run build build-lgx clean

help:
	@echo "make run         launch the standalone muster app (dashboard + walkthrough)"
	@echo "make build       pre-build the runner — the slow first build; do this once"
	@echo "make build-lgx   build muster-ui.lgx (to load into logos-basecamp instead)"
	@echo "make clean       remove local run state (.run/)"
	@echo ""
	@echo "First time: 'make build' (minutes), then 'make run'."
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

build-lgx:
	cd $(UI) && nix build 'path:.#lgx' $(CACHE)

clean:
	rm -rf $(CURDIR)/.run
	@echo "removed .run/ — next launch mints a fresh identity and wallet"

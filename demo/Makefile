# Muster demo — the two-peer send-a-token journey.
#
# Everything runs standalone: `nix run` launches logos-core with chat_module,
# delivery_module and lez_core, and mounts the Muster view. No Basecamp and no
# package manager are involved, so a peer is just a --user-dir.
#
# Peers keep their state under .run/<name>/, which is gitignored. Deleting a
# peer's directory gives it a fresh chat identity *and* a fresh wallet — they
# live in the same instance directory, on purpose (see ChatBackend::walletDir).

UI      := muster-ui
PEER    ?= alice
RUN_DIR := $(CURDIR)/.run

.PHONY: help build app alice bob run clean-peer clean

help:
	@echo "make build          build the muster_ui .lgx"
	@echo "make app            pre-build the standalone runner (do this first; it is the slow one)"
	@echo "make alice          launch the alice peer"
	@echo "make bob            launch the bob peer"
	@echo "make run PEER=carol launch an arbitrarily named peer"
	@echo "make clean-peer PEER=alice   wipe one peer's chat identity and wallet"

# The packaged module, for installing into Basecamp. Not needed for the demo.
build:
	cd $(UI) && nix build 'path:.#lgx' --accept-flake-config

# Build the runner before launching peers: the first launch otherwise spends
# minutes in nix while the window is expected on screen.
app:
	cd $(UI) && nix build 'path:.#default' --accept-flake-config --out-link $(CURDIR)/.run/app

alice:
	$(MAKE) run PEER=alice

bob:
	$(MAKE) run PEER=bob

# One peer. Each gets its own data directory, so two peers are two identities
# with two wallets; the QtRO socket name and delivery ports are chosen per
# instance, so they do not collide.
run:
	@mkdir -p $(RUN_DIR)/$(PEER)
	@echo "launching $(PEER) with user-dir $(RUN_DIR)/$(PEER)"
	cd $(UI) && nix run 'path:.' --accept-flake-config -- --user-dir $(RUN_DIR)/$(PEER)

clean-peer:
	rm -rf $(RUN_DIR)/$(PEER)
	@echo "wiped $(PEER) — next launch mints a new chat identity and a new wallet"

clean:
	rm -rf $(RUN_DIR)

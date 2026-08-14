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

# QML inspector port, so a running peer can be driven and queried the way
# doctests/ do it. Per peer, because two instances on one port collide; the
# numbers match doctests/exchange and doctests/credit so their scripts and a
# hand-launched peer can share a convention. Empty for an unknown PEER name,
# which leaves the inspector off rather than guessing a port.
INSPECT_alice := 3768
INSPECT_bob   := 3769
INSPECT       ?= $(INSPECT_$(PEER))

.PHONY: help build app alice bob run stop clean-peer clean

help:
	@echo "make build          build the muster_ui .lgx"
	@echo "make app            pre-build the standalone runner (do this first; it is the slow one)"
	@echo "make alice          launch the alice peer"
	@echo "make bob            launch the bob peer"
	@echo "make run PEER=carol launch an arbitrarily named peer"
	@echo "make stop           stop every running peer, letting it save first"
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
	@echo "launching $(PEER) with user-dir $(RUN_DIR)/$(PEER)$(if $(INSPECT), (inspector $(INSPECT)))"
	cd $(UI) && QML_INSPECTOR_PORT=$(INSPECT) nix run 'path:.' --accept-flake-config -- --user-dir $(RUN_DIR)/$(PEER)

# Stop peers without destroying their state.
#
# ONLY the top-level app is signalled, and that is the whole point of this
# target existing. ChatBackend's destructor calls chat_module.shutdown(), which
# is what gives the module its chance to write; killing the logos_host_qt
# module hosts alongside the app takes the module away before it can. Doing
# exactly that, on 2026-08-13, threw away a conversation holding a real payment
# receipt -- the state a demo most wants. `pkill -f logos` is not a safe way to
# stop these.
stop:
	@for p in $$(pgrep -f 'logos-standalone-app-bin.*--user-dir $(RUN_DIR)' 2>/dev/null); do \
	  echo "stopping app pid $$p"; kill -TERM $$p 2>/dev/null || true; \
	done
	@for _ in $$(seq 1 30); do \
	  pgrep -f 'logos-standalone-app-bin.*--user-dir $(RUN_DIR)' >/dev/null 2>&1 || break; \
	  sleep 1; \
	done
	@if pgrep -f 'logos-standalone-app-bin.*--user-dir $(RUN_DIR)' >/dev/null 2>&1; then \
	  echo "still running after 30s -- left alone rather than escalating to KILL," >&2; \
	  echo "which is what loses state. Close the window instead." >&2; exit 1; \
	else echo "all peers stopped"; fi

clean-peer:
	rm -rf $(RUN_DIR)/$(PEER)
	@echo "wiped $(PEER) — next launch mints a new chat identity and a new wallet"

clean:
	rm -rf $(RUN_DIR)

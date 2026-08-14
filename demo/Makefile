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
	@echo ""
	@echo "make demo                    restore funded peers, ready to show"
	@echo "make demo-snapshot NAME=x    save the current peers as a fixture"
	@echo "make demo-restore  NAME=x    put a fixture back into .run/"
	@echo "make demo-fixtures           list saved fixtures"
	@echo "  (wallets only -- conversations cannot be saved, see the Makefile note)"
	@echo ""
	@echo "make clean-peer PEER=alice   wipe one peer's chat identity and wallet"

# The packaged module, for installing into Basecamp. Not needed for the demo.
build:
	cd $(UI) && nix build 'path:.#lgx' --accept-flake-config

# Build the runner before launching peers: the first launch otherwise spends
# a very long time in nix while the window is expected on screen.
#
# `.#runner`, not `.#default`. They are different derivations -- `.#default` is
# the .lgx module, while `make run` launches `nix run .` which resolves
# apps.default, the standalone runner. This target used to build `.#default`,
# so it returned in seconds having warmed nothing, and the first launch then
# built the LEZ proving stack from Rust source (measured 2026-08-14: 827 cargo
# derivations and still going at 36 minutes). See exo-d6d and the note on
# `runnerPkg` in muster-ui/flake.nix.
#
# The out-link lives in .tools/ rather than .run/, because `demo-restore`
# wipes .run/ -- which would delete the gc root and let the hour of work be
# collected.
#
# JOBS because nix defaults to max-jobs=1: these are hundreds of small crate
# derivations, so serial builds leave a machine idle. Override for a smaller
# box, e.g. `make app JOBS=2`.
JOBS ?= auto

app:
	@mkdir -p $(CURDIR)/.tools
	cd $(UI) && nix build 'path:.#runner' --accept-flake-config \
	  --max-jobs $(JOBS) --out-link $(CURDIR)/.tools/runner

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
#
# The `bi[n]` is not a typo. `pgrep -f` matches against whole command lines,
# including the shell running this recipe, whose command line contains this
# very pattern -- so a literal spelling makes the target kill itself and the
# make invoking it. The bracket makes the regex match "bin" in the app's
# command line while not matching the literal "bi[n]" in our own.
stop:
	@for p in $$(pgrep -f 'logos-standalone-app-bi[n].*--user-dir $(RUN_DIR)' 2>/dev/null); do \
	  echo "stopping app pid $$p"; kill -TERM $$p 2>/dev/null || true; \
	done
	@for _ in $$(seq 1 30); do \
	  pgrep -f 'logos-standalone-app-bi[n].*--user-dir $(RUN_DIR)' >/dev/null 2>&1 || break; \
	  sleep 1; \
	done
	@if pgrep -f 'logos-standalone-app-bi[n].*--user-dir $(RUN_DIR)' >/dev/null 2>&1; then \
	  echo "still running after 30s -- left alone rather than escalating to KILL," >&2; \
	  echo "which is what loses state. Close the window instead." >&2; exit 1; \
	else echo "all peers stopped"; fi

# ── demo fixtures ───────────────────────────────────────────────────────
#
# Start a demo from peers that are already funded and shielded, instead of
# spending ~15 minutes on a faucet proof-of-work and a shielded transfer while
# an audience watches.
#
# WHAT THIS CAN AND CANNOT CARRY. The wallet, yes: muster-wallet/*.json is our
# own code's state and its notes are real notes on the real chain. The
# conversation, never -- chat_module holds identity and conversations in memory
# only, so every launch has a new address and no history. That is upstream and
# deliberate for now (logos-messaging/libchat#28; see
# poc/BUG-chat-module-state-not-persisted.md). So a demo restores wallets and
# then creates the conversation by hand, every time. Do not go looking for the
# missing half of this feature; it is not implementable from here.
#
# WHY RESTORING INTO A DIFFERENT-LOOKING DIRECTORY WORKS. The host reuses
# whichever instance directory already exists under module_data/<module>/ and
# mints a random name only when none does -- verified 2026-08-14 by renaming a
# peer's instance directory to a fabricated name and watching the host adopt it.
# So the hash-looking directory name in a fixture is arbitrary and need not
# match anything. It does mean a restore must start from an empty .run/<peer>:
# leave two instance directories there and which one the host picks is a
# coin toss.
#
# THESE ARE REAL KEYS. .fixtures/ is gitignored and must stay that way --
# meta.json holds the wallet password in plaintext and storage.json the
# spending keys. A testnet token being worthless is not a reason to publish a
# key. Regenerate rather than share.
#
# NOT IDEMPOTENT. Spending from a restored fixture spends real notes. Show the
# demo twice from one fixture and the second run starts where the first ended,
# which is why `demo` restores first rather than assuming .run/ is clean. Once
# a fixture's notes are gone it needs re-minting.
FIXTURES := $(CURDIR)/.fixtures
NAME     ?= baseline

.PHONY: demo demo-snapshot demo-restore demo-fixtures

# Refuse to touch .run/ while anything is running: the wallet is saved by the
# app, and copying it mid-write yields a fixture that looks fine and is not.
define require_stopped
	@if pgrep -f 'logos-standalone-app-bi[n].*--user-dir $(RUN_DIR)' >/dev/null 2>&1; then \
	  echo "peers are running -- 'make stop' first, or the copy races the wallet save" >&2; \
	  exit 1; fi
endef

demo-snapshot:
	$(require_stopped)
	@if [ ! -d "$(RUN_DIR)" ]; then echo "nothing in .run/ to snapshot" >&2; exit 1; fi
	@rm -rf "$(FIXTURES)/$(NAME)"
	@mkdir -p "$(FIXTURES)/$(NAME)"
	@for p in $$(ls "$(RUN_DIR)" 2>/dev/null); do \
	  [ -d "$(RUN_DIR)/$$p/module_data" ] || continue; \
	  cp -a "$(RUN_DIR)/$$p" "$(FIXTURES)/$(NAME)/"; \
	  echo "snapshotted $$p"; \
	done
	@find "$(FIXTURES)/$(NAME)" -name '*.log' -delete
	@echo "saved to .fixtures/$(NAME) -- $$(find "$(FIXTURES)/$(NAME)" -type f | wc -l) files"

demo-restore:
	$(require_stopped)
	@if [ ! -d "$(FIXTURES)/$(NAME)" ]; then \
	  echo "no fixture named '$(NAME)' -- 'make demo-fixtures' to list" >&2; exit 1; fi
	@rm -rf "$(RUN_DIR)"
	@mkdir -p "$(RUN_DIR)"
	@for p in $$(ls "$(FIXTURES)/$(NAME)"); do \
	  cp -a "$(FIXTURES)/$(NAME)/$$p" "$(RUN_DIR)/"; echo "restored $$p"; \
	done
	@echo "restored from .fixtures/$(NAME). Open each peer's wallet to see the balance:"
	@echo "nothing opens it automatically, so a freshly launched peer looks empty until you do."

# Restore, then hand over. The peers are launched by hand because each is a
# foreground GUI process and wants its own terminal.
demo: demo-restore
	@echo ""
	@echo "ready. In two terminals:  make alice   |   make bob"
	@echo "Then, in the app: open each wallet, share an address, propose, approve, pay."
	@echo "The conversation has to be made fresh every run -- see the note above demo-snapshot."

demo-fixtures:
	@if [ ! -d "$(FIXTURES)" ] || [ -z "$$(ls "$(FIXTURES)" 2>/dev/null)" ]; then \
	  echo "no fixtures yet -- 'make demo-snapshot NAME=...' after funding a peer"; exit 0; fi
	@for f in $$(ls "$(FIXTURES)"); do \
	  printf '%-20s %s\n' "$$f" "$$(ls "$(FIXTURES)/$$f" | tr '\n' ' ')"; \
	done

clean-peer:
	rm -rf $(RUN_DIR)/$(PEER)
	@echo "wiped $(PEER) — next launch mints a new chat identity and a new wallet"

clean:
	rm -rf $(RUN_DIR)

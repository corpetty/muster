# What muster needed from nimside and seaqt

**For:** Jacek (arnetheduck), as the playground's report back (exo-607 T8, `exo-607.11`).
**Status:** written 2026-10-15, after T1b–T7 landed ([corpetty/muster#298](https://github.com/corpetty/muster/pull/298)). Q5 below is still open, and its experiment waits on your answer.
**Reads with:** `docs/design/seaqt-ui.md` (the plan and the evidence, slice by slice), ADR-019 in `docs/02-implementation-plan.md` (the decision).

**Jacek's reply (2026-10-21).** The DSL items are "opinion territory", so each should come as a PR with a working draft and an example. Each seaqt-gen patch should also be its own PR, and he takes them from there. On running seaqt-gen over the Logos C++ modules, he would first like seaqt-gen made standalone:
- it takes a library configuration instead of hardcoding Qt;
- it gets an inventory of the C++ constructs it can translate to C, which are then supported one by one;
- templates are pre-instantiated for a known set of types, such as `QList<int>`.

He did not answer Q5. The PRs opened on 2026-10-24:
- nimside: [seaqt/nimside#1–#11](https://github.com/seaqt/nimside/pulls). #1–#6, #8 and #9 are drafts of the DSL suggestions. #7 documents what a `qobject:` block passes through and fixes four ordering bugs. #10 and #11 fix bugs on master.
- seaqt-gen: [seaqt/seaqt-gen#18–#23](https://github.com/seaqt/seaqt-gen/pulls). These are muster's four patches, a `nim check` fix, and a `go test` fix. When they merge, `ui-nim/nix/seaqt-gen-patches/` can go.

They are tracked as `exo-ea5` (nimside) and `exo-b71d` (seaqt-gen). The standalone design is `exo-0e3`, filed as [seaqt/seaqt-gen#17](https://github.com/seaqt/seaqt-gen/issues/17) ([`seaqt-gen-standalone.md`](seaqt-gen-standalone.md)). Its trial read the Logos SDK's token through `LogosAPI*` from Nim, using bindings generated from the SDK's headers.

## The short version

Muster's whole UI backend now runs on nim-seaqt and nimside: 79 slots and 55 properties, every call to the core asynchronous. It passes the same eleven offscreen self-tests as the C++ backend, on the live Logos fleet, and its QML draws and clicks on a display. The DSL carried it. Nothing in nimside had to be forked. One patch went into nimside for a probe, and four into seaqt-gen for RemoteObjects.

What the playground found, roughly by how much it would help the next app:

1. **The view contract wants first-class support in the DSL.** That means READONLY properties, notifies that carry the value, an interface split from its implementation, and a call hook. Muster got all four by generating a `qobject:` from its `.rep` (`repContract`). That is the biggest single piece of glue the app needed.
2. **The metaobject nimside builds is not moc's.** Accessors become slots, and there is no classinfo. So a QtRO source made from it matches a repc replica only by luck of ordering, and QtRO cannot check the signature.
3. **Initialization and tooling edges:**
   - `nim check` fails on nimside;
   - two `NimMain` calls run every module's top-level code twice;
   - a library built from `exportc` procs cannot be `dlopen`ed.
4. **seaqt-gen runs on more than Qt.** Muster generated QtRemoteObjects at build time with four patches. The same shape would bind the Logos C++ SDK, which is exactly what your Q3 answer points at.

## The numbers

| | C++ (`ui/src`) | Nim (`ui-nim`) |
|---|---|---|
| The backend | `muster_ui_backend.cpp` + `.h`: 1,524 lines | `app/backend.nim`: 1,157 lines |
| The host | the Logos builder's generated plugin glue and `ui-host` | `app/muster_app.nim` 186 + `app/logos_core.nim` 67 + `app/sched.nim` 70 |
| The contract | `muster_ui.rep`, through repc | the same `.rep`, through `repContract` (`contract/`, 328 lines) |
| The module client | generated C++ (`LogosModules`), synchronous | generated Nim from `muster.lidl`: 92 methods, each sync, raising and async |
| Calls into the core | blocking, in `ui-host`'s own process | async on the GUI thread: 89 call sites, no worker thread |
| Parity suite | 11/11 | 11/11 |

## For nimside (the DSL)

Each item gives what muster needed, what it did, and what the DSL could offer.

### The view contract

| Need | What muster did | Could the DSL say it? |
|---|---|---|
| **A property QML reads but cannot write, which Nim sets.** This is repc's READONLY, and it is the norm for a view contract. | `qproperty(write = false)` plus a generated Nim `setX` that emits the notify only on change. | A `readonly` (or `write = nim`) property kind. |
| **A notify that carries the value**, as `healthChanged(QString)` does in moc and repc. | Nothing. QtRO does not need it, but a Nim or C++ listener cannot read the value from the signal. | Notifies with the new value as their argument. |
| **An interface, implemented elsewhere.** | `repContract` forward-declares `<slot>Impl` for every slot, so a missing one fails the compile, like a pure virtual. Because forward declarations must share a module, `backend.nim` is `include`d. | An `interface` or `contract` block that a separate module implements. |
| **A hook in every slot.** The view-only self-test records which slots QML called, with no core behind it. | `repContract` calls `onSlot(o, name)` first in each slot, when the module declares one. | A slot interceptor, or before/after hooks. |
| **Slots that never unwind into Qt.** | The generated slot wraps its Impl in `try … except Exception`, and reports the error. | The DSL could generate the guard (the slots are `raises: []` already). |

`repContract` (`ui-nim/contract/repcontract.nim`, 144 lines plus a 184-line parser) is, in effect, a repc for nimside. Its check proves the generated object is the contract, index for index, against what repc emits for the C++ build: 55 properties, 55 notifies and 79 slots, plus every `backend.<name>` the QML uses. If nimside grew the four features above, most of it would collapse into a declaration.

### The metaobject

- **Accessors become slots.** nimside registers each property's getter (and setter) as a slot; moc and repc do not. A QtRO dynamic source therefore remotes 55 extra methods. A typed replica is safe only because they happen to sort after the declared slots, and nimside does not promise that order.
- **No classinfo and no `Q_INTERFACES`.** QtRO's "RemoteObject Signature" cannot be declared, so QtRO skips its source/replica check. A `metacast` override stood in for `Q_INTERFACES` in the Basecamp probe. It worked, but as an ABI impersonation, not something to ship.
- **Slot parameter types are a closed list.** An opaque pointer (`LogosAPI*`) was rejected until a six-line patch let a type name its Qt type (`qtTypeName`).
- **A non-slot proc in a `qobject:` body passes through, in order.** That is undocumented, and `repContract`'s forward declarations rely on it.

### Plugins (option A, not pursued)

`Q_PLUGIN_METADATA` builds its instance as a hidden `T()`, so a plugin cannot construct it, and its `.rep` defaults never run. It cannot emit the `MetaData` key either, and its strings are capped at 255 bytes, while muster's `metadata.json` is about 1.2 KB. These only matter for a Nim plugin inside Basecamp's `ui-host`, which ADR-019 set aside. They come back when Basecamp can load a Nim UI.

## For seaqt and seaqt-gen

- **RemoteObjects, generated at build time.** It took four patches to seaqt-gen `56485e6`; they are in `ui-nim/nix/seaqt-gen-patches/`, and `0001`, `0003` and `0004` are worth upstreaming:
  - `0001` adds the module to the module list;
  - `0002` adds a module filter (local only);
  - `0003` fixes a parameter named `self`, which collides;
  - `0004` fixes `QSet<T>` returns emitting invalid Nim, a bug that already ships unexercised in QtStateMachine and QtDesigner.

  The generator needs clang 14.0.6: from clang 16 it prints nested types unqualified and panics. The output is reproducible.
- **seaqt-gen on any C++.** This is your Q3 direction, and muster has a first customer for it. Basecamp's capability token reaches a plugin only as a C++ `LogosAPI*`, whose accessors are non-virtual and statically linked into `ui-host`. Bindings generated from the Logos C++ SDK's headers would turn that hard blocker into a build step.
- **`nim check` cannot type-check a nimside program.** `qtcore_pkg.nim` reads the Qt version with `gorge("pkg-config …")`. `nim check` runs no `gorge`, so nimside's metaobject generator fails with "Unsupported Qt version". `nim c --compileOnly` works, and muster's edit loop used it. nimsuggest is presumably hit the same way. A `-d:QtCoreBuildVersion=` override, or a fallback, would fix it.
- **Slot closures must be spelled `{.closure, raises: [].}`** (`QTimer.onTimeout`). It is correct, but every first use trips on it.
- **`acquireDynamic` returns `owned: false`.** Nim never deletes the replica, so it must be parented or deleted by hand.
- **No QString type.** A string argument to `invokeMethod` goes in as `QGenericArgument.create("QString", QVariant.constData())`.
- **QtQuickControls2 is not bound,** so there is no `QQuickStyle`. The app sets `QT_QUICK_CONTROLS_STYLE=Basic` before the application exists.
- **Versions.** `qt-6.8` compiled on Qt 6.9.2 without `-fpermissive` (nora-poc needed it). `qt-6.11` worked on 6.11.2 with no change: `hello`, the contract and the real app passed on first build. RemoteObjects regenerated against 6.11.2 with the same four patches.

## Around the edges (Logos and the SDK, for the record)

- **logos-nim-sdk gained an async client.** [#7](https://github.com/corpetty/logos-nim-sdk/pull/7) adds `<method>Async(…, done)` beside the plain and raising twins, and `PluginProxy.callAsyncThen`, which carries a Nim closure across the C callback. On the QtRO transport, results land on the client's thread, so a Qt app sets a property straight from `done`. No chronos or thread channel was needed, contrary to the plan's assumption from nora-poc.
- **Two `NimMain`s.** The module surface that logos-nim-sdk generates installs a C constructor that calls `NimMain` at load. That is how the plugin initializes. A Nim executable that links the module then runs `NimMain` twice, and every module's top-level code with it. The ported probe harness had to be built `--noMain`. Worth a guard in the generated surface, or a note.
- **`exportc` without `dynlib` is hidden.** That is fine for the staticlib the builder links into the plugin, but a shared build of the module exports none of `logos_module_*`, so it cannot be `dlopen`ed.
- **One Qt per process.** The app process loads `liblogos_core` and `liblogos_protocol`, both of which link Qt. So the move to Qt 6.11 meant rebuilding them on the app's Qt. Building them on nixos-unstable took three overrides: GCC 14, Boost 1.87, and `-include cstring` for fmt 12. It also needed the lesson that an overlay changing `boost` rebuilds Qt from source; the cure was attribute replacement, not an overlay (`docs/labbook/logos-libraries-on-a-newer-nixpkgs.md`). The module processes stay on Logos's Qt 6.9.2, and QtRO's wire (`QtRO 2.0`, `QDataStream::Qt_6_2`) is the same in both.

## Q5: what should the DSL be? (open)

You have not answered this one yet:

- **The layer.** Is the DSL nimside's `qobject:` layer, or something higher, that also declares views?
- **The type set.** Should muster's contract move from JSON strings to typed models, to make the playground "sufficiently complex"?

The current contract is 55 string properties and 79 string slots. The DSL's type set (scalars, `string`, `seq[string]`, QObject) covers it with room to spare, so it does not yet stress nimside's types, models, nested objects or cross-thread signals.

If you want the playground pushed there, here is a scoped experiment. It is ready to start on your word.

- **One surface, typed end to end.** Replace `intentsJson`, the room's proposals as a JSON array that the QML parses on every tick, with a list model of intent objects:
  - fields: state, effect, approvals, parts;
  - a signal with arguments when one changes;
  - updates from the async callbacks.
- **What it exercises:** `VirtualQAbstractListModel` from nimside, nested QObjects, signals with arguments, and a model that QML binds to directly.
- **Why it stays honest:** the `.rep` contract would no longer be all strings, so the C++ Basecamp build (frozen, and still the catalogue's) would need the same change, or the two builds would diverge. One answer is to keep the typed model Nim-only, beside the string property, until Basecamp can load a Nim UI.

Your answer to the first half (the DSL's layer) decides whether this is done in `qobject:` terms or in whatever sits above it.

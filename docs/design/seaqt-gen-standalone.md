# seaqt-gen on any C++: a library configuration, a feature inventory, templates

Notes for Jacek on the three things you listed on 2026-10-21: a standalone tool that takes a
library configuration instead of hardcoding Qt, an inventory of the C++ constructs that can be
projected to C, and templates by pre-instantiation. Muster's interest is narrow and concrete:
Basecamp hands a plugin its capability token only as a C++ `LogosAPI*` whose accessors are
non-virtual (muster `docs/design/seaqt-dsl-feedback.md`, "seaqt-gen on any C++";
`docs/design/seaqt-ui.md` §9 T4b). Bindings generated from the Logos C++ SDK headers turn that
into a build step. §5 shows it working.

Everything below is against seaqt-gen master `56485e6d`. Line numbers are master's.

*Muster's copy (exo-0e3, 2026-10-24).* The branch `logos-sdk-trial` it cites is a local prototype and was not pushed, so its commits resolve only on the machine that produced it.

## 0. How the evidence was produced

- **Toolchain.** clang 14.0.6 (nixpkgs `b134951a`, the generator's Docker version), Go 1.26.8, and Qt 6.11.2 from nixos-unstable `7fd4004d` (`qt6.env` with qtremoteobjects and qtdeclarative, so there is one merged include tree). Modules Core, Gui, Widgets and Network were run through muster's `SEAQT_GEN_MODULES` filter (patch 0002 in `ui-nim/nix/seaqt-gen-patches`). This is the same recipe as muster's `ui-nim/nix/seaqt-ro.nix`.
- **First trap.** nixpkgs builds Qt with `FEATURE_reduce_relocations`, so `qcompilerdetection.h` `#error`s unless `-fPIC` is set. Outside a nix build the clang wrapper does not add it. The generator then logged `Skipping <header>: ... exit status 1` for 216 of QtCore's 252 headers and carried on. That is commit `1046237f`'s "allow clang to fail and simply skip that file" working as designed. I used a wrapper that adds `-fPIC`.
- **Reproducibility.** The run reproduces the published `nim-seaqt` `qt-6.11` branch (`41a8f1b1`). QtCore, QtGui and QtWidgets match file for file, except for the `GenVersion` string and one enum whose value is `QT_VERSION` (6.11.1 there, 6.11.2 here). QtNetwork has two extra headers, `qsctpserver.h` and `qsctpsocket.h`, because nixpkgs' Qt is built with SCTP.
- **Determinism.** A second build, instrumented with extra log output only, wrote output byte-identical to the plain build. Byte-identical refactoring (§2.4) can therefore be checked with `diff -r`.
- **Scale and speed.** 544 headers produce 31,280 C functions. A cold run takes 11m50s on a shared 64-core host; a run with a warm AST cache takes 11s.
- **Instrumentation.** For the tallies in §3, every `return ErrTooComplex` in `config-allowlist.go` was rewritten to carry its line number and the offending type. The clang filter counts the nodes it drops, but only those located in the header being parsed. The scripts are in my scratchpad and are not part of any branch. The rule-in-the-message part is worth upstreaming (PR 1, §6).

## 1. Where Qt is hardcoded

### 1a. Qt as library configuration: data that should come from a config file

| Where | What | Becomes |
|---|---|---|
| `config-libraries.go:18-31` | The version comes from `qmake -query QT_VERSION`. `CacheSubdir = "qt"+major.minor`. The run dispatches on major 5 or 6 and panics otherwise. | `version`, `name` |
| `config-libraries.go:33-76`, `78-119` | Two near-identical functions. They differ only in the module list, the pkg-config name (`"Qt5"+lib` / `"Qt6"+lib`), the header dir (`QT_INSTALL_HEADERS/Qt<lib>`), `--std=c++17` (Qt 6 only), `InsertTypedefs(bool)`, and the output dirs `seaqt-<mm>/seaqt` and `nim-seaqt-<mm>/seaqt`. | `modules[]`, `clang`, `output` |
| `qmake.go` (whole file) | Finds qmake and queries it. | a `vars` source (`{"qmake": "QT_INSTALL_HEADERS"}`) |
| `main.go:125-149` | The private-header dir `QT_INSTALL_HEADERS/<Module>/<module version>`. The QtCore include dirs are always added when the module is not QtCore. | `modules[].includeDirs` |
| `main.go:21-25` | The cache path `cachedir/<CacheSubdir>/<header path>`, default `qt5`. | `name` |
| `config-allowlist.go:8-59` | `InsertTypedefs`: seeded typedefs (`QStringList`, `QVariantList`/`Map`/`Hash`, `QFile::FileTime`, …) and one seeded enum (`QWebPluginFactory::Extension`). | `typedefs`, `enums` |
| `config-allowlist.go:61-103` | `AllowHeader`: `_impl.h`, `opengl`/`vulkan`, and 24 exact filenames. | `policy.skipHeaders` |
| `config-allowlist.go:105-132` | `HeaderPlatformRestriction`: `qsharedmemory.h` gets `!defined(Q_OS_ANDROID)`, plus a Go build tag. | `policy.headerPlatform` |
| `config-allowlist.go:134-172` | `ImportHeaderForClass`: a class whose name starts with `Q` gets `#include <ClassName>` (Qt's per-class forwarding headers), except `QPlatform*`, `Qsci*`, `Qwt*` and 9 named classes. | `output.includeForClass`, `policy.noInclude` |
| `config-allowlist.go:174-269` | `AllowClass`: `*Private*` names, `QPrivateSignal`, the `std::` prefix, and about 70 named classes. | `policy.skipClasses` |
| `config-allowlist.go:271-285` | `AllowSignal`: void-only, minus `metaObject`/`qt_metacast`/`clone`. | `policy.signalExclude` |
| `config-allowlist.go:287-294`, `935-955` | Inheritance overrides (`QList<` bases, Qwt). | `policy.inheritance` |
| `config-allowlist.go:296-419` | `AllowVirtualForClass`: about 35 classes, mostly link errors. | `policy.noVirtual` |
| `config-allowlist.go:421-575` | `AllowMethod`/`AllowCtor`: per-class, per-method and per-parameter rules (circular deps, forward-incompatible methods, `QGADGET`, int-by-reference returns, …). | `policy.skipMethods[]` (matchers) |
| `config-allowlist.go:580-886` | `AllowType`: container recursion, about 30 template-prefix blocks, `std::`, out-parameter rules, and an exact list of about 100 types. | `policy.skipTypes[]` |
| `config-allowlist.go:890-930` | `ApplyQuirks`: `RequireCpp` and `BecomesConst*InVersion`, keyed on pkg names `"Qt6Core"`/`"Qt6Network"`. | `quirks[]` |
| `main.go:180-192` | A synthesized `QVariant::fromValue(QObject*)` when the header is `qvariant.h`. | `quirks[].addMethod` |
| `clang2il.go:148-156` | Name hacks: `FromBase64Result` becomes `QByteArray::FromBase64Result`, `Connection` becomes `QMetaObject::Connection`. | `quirks[].rename` |
| `clang2il.go:474-477`, `intermediate.go:99-101`, `config-allowlist.go:147-155, 328-333, 397-404, 674-681` | Leftovers for Qwt, QScintilla and Scintilla from miqt's extra libraries. They show the core has carried other libraries' policy before. | moves with those libraries' configs |
| `clang2il.go:766-768` | The `QDataStream` `operator<<`/`>>` return type is rewritten to void. | `quirks[]` |
| `emitcabi.go:892-901` | `QT_VERSION_CHECK` is injected into `qobject.h`'s C header when the module is `QtCore`. | `runtime` / `quirks[]` |
| `emitnim.go:921-981` | `qobject.h`'s Nim unit compiles `../libseaqt-runtime.cpp` with QtCore's private include dir, and defines `connectRaw`. | `runtime.unit` |
| `emitnim.go:850-866` | The `*_pkg.nim` reads cflags, libs and version from one pkg-config name per module (`gorge`). | `modules[].pkgconfig`, plus `cflags`/`libs` |
| `emitnim.go:1682-1689` | `seaqt.nimble`, with author `seaqt`, "Generator-based bindings for Qt/QML" and version `0.<qtversion>.0`. | `output.nimble` |

### 1b. Qt-isms in the core: mechanisms a configuration must be able to express or switch off

1. **QObject and moc.**
   - **Signal detection.** A method counts as a signal when its `AccessSpecDecl` came from a macro expansion (`clang2il.go:237-244`, `406`). Any library whose macros expand to an access specifier is misread. I checked this on a non-Qt class: `#define LIB_API_SECTION public:` followed by `void refresh();` gave `lib__Widgetish_connect_refresh`, and the wrapper did not compile: `no member named 'connect' in 'lib::Widgetish'`. The Logos SDK's `LOGOS_PROVIDER` macro (`logos_provider_object.h`) expands to `public:` … `private:`. It escapes only because the methods inside it are not void.
   - **The rest of the QObject machinery.** `QPrivateSignal` (`clang2il.go:544-551`, `emitcabi.go:1489-1525`). The connect wrapper `ClassName::connect(...)` (`emitcabi.go:1455-1486`, `emitnim.go:1247-1285`). `staticMetaObject` as the only static data member (`clang2il.go:511-515`, `emitcabi.go:1038-1041, 1556-1559`, `emitnim.go:1631-1642`). `deleteLater` for the class named exactly `QObject` (`emitnim.go:231-233, 1072-1080, 1222`). `connectRaw` and the runtime (`emitnim.go:921-981`).
   - **Patterns.** The receiver/member pattern (`intermediate.go:296-316`, `config-allowlist.go:480`). The `argc`/`argv` pattern (`intermediate.go:283-294`, `emitnim.go:513-560`).
   - **What the config needs.** `features.qobject` in three modes: `"all"` (today), `"derived"` (only classes deriving from a known `QObject`; this is what the Logos SDK needs), and `"off"`.
2. **Type projections hardwired by name.**
   - **Strings.** `QString`, `QAnyStringView`, `QByteArray` and `QByteArrayView` become `seaqt_string` in C (`emitcabi.go:86-88, 286-325, 494-552, 726-728`) and `string`/`openArray[char]`/`seq[byte]` in Nim (`emitnim.go:258-279, 445-450, 566-581, 730-746`). They also count as "class types" (`intermediate.go:103-106`).
   - **Containers.** `QList`/`QVector` (`intermediate.go:116-130`), `QSet` (`181-189`), `QMap`/`QHash` (`132-162`) and `QPair` (`164-179`). `QMultiMap`/`QMultiHash` are blocked (`191-198`). `QFlags<E>` becomes the int of `E` (`65-87`).
   - **Where else the names appear.** `cabiPreventStructDeclaration` (`emitcabi.go:853-860`), `getReferencedTypes` (`761-777`), and `applyTypedefs`' container recursion (`transformtypedefs.go:13-51`).
   - **What the config needs.** Named projection sets, implemented in Go and selected by the config: `qt.strings`, `qt.containers`, `qt.qflags`, and later `std.string`, `std.vector`, `std.function`.
3. **Integer vocabulary.** `IntType` lists `qint*`, `qreal`, `qsizetype` and `QIntegerForSizeof<…>` (`intermediate.go:200-231`). The C spellings are in `emitcabi.go:116-158`, the Nim spellings in `emitnim.go:329-387`, and hard casts for `qintptr`/`qsizetype` in `emitcabi.go:419-430, 667-669`. In the config this becomes an `intTypedefs` table; std's `int64_t` etc. are already covered.
4. **Naming.**
   - **Prefixes stripped.** `Qt::` is stripped from C names (`emitcabi.go:847`) and `qt_` from method names (`intermediate.go:320`, `emitnim.go:63`).
   - **Q_PROPERTY setter heuristic.** A setter's unnamed parameter takes its name from the setter (`clang2il.go:727-728`).
   - **Include guard.** `SEAQT_<MODULE>_GEN_<FILE>` (`emitcabi.go:865`).
   - **Module and package names.** Module dirs are `Qt<lib>`. The package is `<lower(module)>_pkg.nim` with `<Module>CFlags`/`Libs` constants (`emitnim.go:227-229, 850-866`).
   - **Flat forwarders.** One forwarder per class goes to `seaqt/<lower(ClassName)>.nim` (`main.go:261-270`). For a second library, these share one flat namespace with Qt's. The Logos trial wrote `seaqt/timeout.nim` and `seaqt/logosapi.nim` next to `seaqt/qobject.nim`.
   - **Generated names.** C names are `ns__Class`, Nim names `nsClass` (`emitnim.go:162-179`), and enums `…Enum`. The subclass is `Virtual<Class>`.
5. **Version gates.** `QT_VERSION`/`QT_VERSION_CHECK` in `BecomesConstInVersion` and `BecomesNonConstInVersion` (`emitcabi.go:985-991, 1399-1428`). The Nim side has `GenVersion`/`BuildVersion` (`emitnim.go:858-862`). In the config this becomes `features.versionGates` with the macro names.
6. **Includes.** The wrapper `.cpp` includes `<ClassName>` for each referenced class (`emitcabi.go:1097-1101`), and the header itself by basename (`1104`). A library without per-class headers works only through that second include.
   - It also depends on Qt pulling in `<new>`: with no Qt header in the chain, the wrappers fail on `std::nothrow` (prototype in §4.3). The generator should emit `#include <new>` itself.
7. **Runtime.** `libseaqt-runtime.h` is generic: `seaqt_string`/`array`/`map` and `seaqt::release_callback`. `libseaqt-runtime.cpp` is Qt-only: `QObject_connectRawSlot` over `private/qobject_p.h`. The Makefile overlays both onto the output, not genbindings (`Makefile`, `genbindings-%` target). The generated header includes the runtime as `../libseaqt-runtime.h` relative to the module dir (`emitcabi.go:867-871`). In the config: `runtime.header`, plus the generic and Qt parts split into two files, so a non-Qt library can ship the header alone.
8. **Global type state.** `KnownClassnames`, `KnownTypedefs` and `KnownEnums` are flushed once per Qt major (`config-libraries.go:34, 79`) and accumulate in module-list order. Dependency order is therefore implicit in the list.
   - A class whose base is not known panics (`intermediate.go:643`).
   - Nim cross-module imports assume a sibling dir, `../<Module>/` (`emitnim.go:25-29`).
   - In the config this becomes `depends[]`, with a persisted type index and an import root (§2).
9. **Leftover Go and miqt bits.** `RequireGOOS`, `AndroidBlockedPlatform.GoBuildTag`, and `transformctors.go`, which is never called.

### 1c. Generic-tool hazards found on the way

None of these is a Qt assumption, but each would bite the first non-Qt user.

- **The AST cache is keyed on the header path only** (`main.go:23-28`, `clangfilter.go:266-287`). Changing the header, the cflags, the clang version or the filter does not invalidate it. I hit this: an edited probe header was regenerated from the stale AST. Key the cache on (header content hash, cflags, clang version, filter version).
- **A clang failure silently skips the whole header** (`main.go:100-104`). With bad cflags the result is "bindings with most of the library missing". One summary line saying "N headers failed to parse" at the end would catch it.
- **Two inputs panic the whole run** in `emitCabiToNim` (`emitnim.go:844`): a by-value use of an uninstantiated class template (`Box<int> box() const`) and a public array field (`int arr[4];`; only `char[`, `quint8[` and `uint[` fields are filtered, at `clang2il.go:463-467`). Both should be blocked with a reason.
- **Varargs emit uncompilable code.** `void varargs(const char* fmt, ...)` became `self->varargs(fmt, );`.
- **A pure virtual can be blocked while the class stays subclassable.** The `Virtual…` subclass is then abstract and does not compile. Logos SDK: `LogosProviderObject::setEventListener(std::function<…>)` is blocked, so `VirtualLogosProviderObject` fails to compile with "allocating an object of abstract class type".
- **Block messages carry no reason.** Every block prints the same `Type declaration is too complex to parse`. The instrumentation that produced §3 should be the default.

## 2. A library configuration

### 2.1 The format

JSON, read with `encoding/json`: the generator has no third-party Go dependencies, and muster builds it with `GOPROXY=off`. The two Qt configs are embedded with `go:embed`, so `genbindings` with no flag still produces today's output. String values may reference `${var}`; a var's value comes from `qmake`, `pkgconfig`, `env` or a literal.

```go
type Library struct {
	Name        string                 `json:"name"`    // "qt6": cache subdir, default output names
	Version     Source                 `json:"version"` // {"qmake":"QT_VERSION"} | {"pkgconfig":"Qt6Core"} | {"value":"0.1.0"}
	Vars        map[string]Source      `json:"vars"`    // "qtHeaders": {"qmake":"QT_INSTALL_HEADERS"}
	Depends     []Dependency           `json:"depends"` // libraries whose types may be referenced
	Clang       Clang                  `json:"clang"`
	Output      Output                 `json:"output"`
	Runtime     Runtime                `json:"runtime"`
	Features    Features               `json:"features"`
	Projections []string               `json:"projections"` // Go-implemented sets: "qt.strings", "qt.containers", "qt.qflags", "std.string", ...
	IntTypedefs map[string]string      `json:"intTypedefs"` // "qint64": "int64_t", "qreal": "double", ...
	Typedefs    map[string]string      `json:"typedefs"`    // seeded aliases (today's InsertTypedefs)
	Enums       map[string]string      `json:"enums"`       // seeded enums: name -> underlying type
	Modules     []Module               `json:"modules"`     // generated in order
	Policy      Policy                 `json:"policy"`
	Quirks      []Quirk                `json:"quirks"`
	Instantiate []Instantiation        `json:"instantiate"` // §4
}

type Source struct{ Qmake, Pkgconfig, Env, Value string }

type Module struct {
	Name        string   `json:"name"`        // "QtCore": dir, Nim package prefix, include guard
	Pkgconfig   string   `json:"pkgconfig"`   // clang cflags, and what *_pkg.nim gorges
	Headers     []string `json:"headers"`     // dirs (every .h) or single files
	IncludeDirs []string `json:"includeDirs"` // extra -I for clang only (private headers)
	Cflags      []string `json:"cflags"`      // extra flags in the emitted *_pkg.nim
	Libs        []string `json:"libs"`        // extra link line in the emitted *_pkg.nim
}

type Dependency struct {
	Library string   `json:"library"` // another config, by name or path
	Modules []string `json:"modules"` // e.g. ["QtCore"]: load their type index, not their headers
	Import  string   `json:"import"`  // Nim import root for that library, e.g. "seaqt"
}

type Clang struct {
	Std     string   `json:"std"`
	Args    []string `json:"args"`    // e.g. ["-fPIC"]
	Defines []string `json:"defines"` // e.g. ["SEAQT_GEN_PARSE"] (§4)
}

type Output struct {
	CDir, NimDir       string // "seaqt-${version.mm}/seaqt", "nim-seaqt-${version.mm}/seaqt"
	Forwarders         bool   // seaqt/<lowerclass>.nim
	IncludeGuardPrefix string // "SEAQT"
	IncludeForClass    string // "<${class}>" for Qt; "" = rely on the header's own includes
	StripClassPrefix   []string // ["Qt::"]
	StripMethodPrefix  []string // ["qt_"]
	Nimble             *Nimble  // nil = no .nimble
}

type Runtime struct {
	Header string // "libseaqt-runtime.h", relative to the output root
	Unit   string // header whose Nim unit compiles the runtime .cpp ("qobject.h"); "" = none
}

type Features struct {
	QObject         string // "all" (today) | "derived" | "off"
	VersionGates    string // "QT_VERSION" (today) | ""
	ArgcArgv        bool
	ImplicitCtors   bool   // new: synthesize from definitionData (§3)
	Exceptions      string // new: "ignore" (today) | "catch"
	FreeFunctions   bool   // new (§3)
}

type Policy struct {
	SkipHeaders   []Match      // {exact|suffix|contains, reason}
	SkipClasses   []Match
	NoInclude     []Match
	NoVirtual     []Match
	SkipMethods   []MethodRule // {class, method, paramType, returnType, static, reason, errKind}
	SkipTypes     []TypeRule   // {exact|prefix|contains, unlessPointer, paramOnly, pointerDepth, reason}
	Platform      []PlatformRule
	SignalExclude []string
}
```

`MethodRule` and `TypeRule` are flat matchers. Every rule in today's `AllowMethod` and `AllowType` fits one, because each is "class X and method Y", "parameter type is Z", "prefix P" or "pointer and not a return type" (`config-allowlist.go:421-886`). Evaluation order is the list order, which keeps the first-match behaviour identical.

### 2.2 Qt 6 as one configuration (abridged)

The data below is the data of today's `buildQt6` (`config-libraries.go:78-119`) and `config-allowlist.go`.

```json
{
  "name": "qt6",
  "version": {"qmake": "QT_VERSION"},
  "vars": {"qtHeaders": {"qmake": "QT_INSTALL_HEADERS"}},
  "clang": {"std": "c++17"},
  "output": {
    "cDir": "seaqt-${version.mm}/seaqt", "nimDir": "nim-seaqt-${version.mm}/seaqt",
    "forwarders": true, "includeGuardPrefix": "SEAQT", "includeForClass": "<${class}>",
    "stripClassPrefix": ["Qt::"], "stripMethodPrefix": ["qt_"],
    "nimble": {"name": "seaqt", "version": "0.${version}.0", "description": "Generator-based bindings for Qt/QML"}
  },
  "runtime": {"header": "libseaqt-runtime.h", "unit": "qobject.h"},
  "features": {"qobject": "all", "versionGates": "QT_VERSION", "argcArgv": true},
  "projections": ["qt.strings", "qt.containers", "qt.qflags"],
  "intTypedefs": {"qint8": "int8_t", "quint8": "uint8_t", "qint64": "int64_t", "qreal": "double", "qsizetype": "ptrdiff_t", "...": "..."},
  "typedefs": {"QStringList": "QList<QString>", "QVariantList": "QList<QVariant>", "QVariantMap": "QMap<QString,QVariant>", "...": "..."},
  "modules": [
    {"name": "QtCore", "pkgconfig": "Qt6Core", "headers": ["${qtHeaders}/QtCore"],
     "includeDirs": ["${qtHeaders}", "${qtHeaders}/QtCore", "${qtHeaders}/QtCore/${module.version}"]},
    {"name": "QtGui", "pkgconfig": "Qt6Gui", "headers": ["${qtHeaders}/QtGui"],
     "includeDirs": ["${qtHeaders}", "${qtHeaders}/QtGui", "${qtHeaders}/QtGui/${module.version}",
                     "${qtHeaders}/QtCore", "${qtHeaders}/QtCore/${version}"]},
    "... Widgets, Network, Multimedia, ... as in config-libraries.go:94-110"
  ],
  "policy": {
    "skipHeaders": [{"suffix": "_impl.h"}, {"contains": "opengl"}, {"contains": "vulkan"},
                    {"exact": "qstring.h", "reason": "QString is projected"}, "..."],
    "skipClasses": [{"suffix": "Private"}, {"prefix": "std::"}, {"exact": "QException", "reason": "extends std::exception"}, "..."],
    "noVirtual":   [{"exact": "QAccessibleWidget", "reason": "undefined vtable at link"}, "..."],
    "skipMethods": [{"class": "QMediaPlayer", "paramType": "QVideoWidget", "reason": "circular dep"},
                    {"method": "*QGADGET*"}, {"returnIntByRef": true, "reason": "e.g. QSize::rheight"}, "..."],
    "skipTypes":   [{"prefix": "QBindable<"}, {"prefix": "std::"}, {"contains": "(*)", "reason": "function pointer"},
                    {"exact": "QString", "pointer": true, "paramOnly": true, "reason": "out-parameter"},
                    {"exact": "QStringView"}, {"exact": "QLatin1String"}, "..."]
  },
  "quirks": [
    {"returnType": "Q_PID", "requireCpp": "defined(Q_OS_LINUX)"},
    {"module": "QtCore", "class": "QObjectData", "method": "dynamicMetaObject", "returnBecomesConstIn": "6.9"},
    {"header": "qvariant.h", "class": "QVariant", "addMethod": {"name": "fromValue", "static": true,
      "return": "QVariant", "params": [{"name": "value", "type": "const QObject*"}]}},
    "..."
  ]
}
```

### 2.3 The Logos C++ SDK as a second configuration

This is what §5's trial had to hard-code. Every field below corresponds to a sed edit or a Go literal there.

```json
{
  "name": "logos-sdk",
  "version": {"value": "0.1.0"},
  "vars": {"sdk": {"env": "LOGOS_CPP_SDK"}, "sdkLib": {"env": "LOGOS_CPP_SDK_LIB"}},
  "depends": [{"library": "qt6", "modules": ["QtCore"], "import": "seaqt"}],
  "clang": {"std": "c++17", "args": ["-fPIC"]},
  "output": {"cDir": "logos-sdk/c", "nimDir": "nim-logos-sdk/logos", "forwarders": false,
             "includeGuardPrefix": "LOGOS", "includeForClass": ""},
  "runtime": {"header": "libseaqt-runtime.h"},
  "features": {"qobject": "derived", "implicitCtors": true, "exceptions": "catch", "freeFunctions": true},
  "projections": ["qt.strings", "qt.containers", "std.function"],
  "modules": [{
    "name": "LogosSdk", "pkgconfig": "Qt6Core",
    "headers": ["${sdk}/cpp/logos_api.h", "${sdk}/cpp/token_manager.h", "${sdk}/cpp/logos_api_client.h",
                "${sdk}/cpp/logos_object.h", "${sdk}/cpp/logos_types.h", "${sdk}/cpp/logos_mode.h",
                "${sdk}/cpp/logos_api_provider.h", "${sdk}/cpp/logos_provider_object.h", "${sdk}/core/interface.h"],
    "includeDirs": ["${sdk}/cpp", "${sdk}/core"],
    "cflags": ["-I${sdk}/cpp", "-I${sdk}/core"],
    "libs": ["${sdkLib}", "$(pkg-config --libs Qt6RemoteObjects)"]
  }],
  "policy": {"skipMethods": [{"class": "LogosProviderBase", "method": "setEventListener",
                              "reason": "until std.function lands"}]}
}
```

### 2.4 The smallest refactor sequence, with Qt byte-identical at each step

Each step is checked by `diff -r` against the previous step's output, with the same pinned Qt. §0 shows that the output is deterministic, and that the nix recipe reproduces the published `nim-seaqt` branches up to the version stamp. So the published branches can serve as the reference too.

0. **Golden harness.** A `make golden MODULES=Core,Gui,Widgets,Network` target, or a Go test with `-short`, runs the generator into a temp dir and diffs it against a reference dir. A module filter is needed for this to be fast (muster's patch 0002; branch `module-filter` in the PR set). It changes no output.
1. **Data structures.** Introduce `Library`/`Module` as Go structs. `buildQt5`/`buildQt6` become `qt5()`/`qt6()` constructors returning data, and `generate(lib, mod)` replaces the 10-string signature (`main.go:112-115`). The version, cache dir and output dirs are computed from `Library`.
2. **Literal checks.** Replace the hard literal checks with fields:
   - `qtModuleName != "QtCore"` (`main.go:143`) becomes each module's `IncludeDirs`;
   - `filename == "qobject.h" && qtModuleName == "QtCore"` (`emitcabi.go:892`) and `headerName == "qobject.h"` (`emitnim.go:921`) become `Runtime.Unit`;
   - `qvariant.h` (`main.go:180`) becomes a `Quirk`;
   - `writeNimbleFile` becomes `Output.Nimble`.
3. **Allowlist tables.** Move the allowlist into `Library.Policy` and `Library.Quirks`, still as Go literals, read by the existing `AllowX` functions in the same order. Then add the JSON loader, `-config <file>`, and the embedded `qt5.json`/`qt6.json` with the same data. With no `-config`, the embedded config is picked by the qmake major as today.
4. **Feature gates.** Add the gates (`QObject`, `VersionGates`, `ArgcArgv`); the Qt configs set today's values. `QObject: "derived"` makes signal detection, connect, `staticMetaObject` and `deleteLater` depend on the class inheriting from a known `QObject`. That keeps Qt output identical only if no non-QObject Qt class has a macro-expanded access specifier. The golden diff checks this; if it fails, Qt keeps `"all"`.
5. **Projections.** Name the projection sets. The hardwired `QString`/`QList`/… branches move behind `projections` lookups. The code is unchanged.
6. **Dependencies.** At the end of a module's pass 1, write a type index next to the output: `KnownClassnames`, `KnownTypedefs` and `KnownEnums` filtered to that module (the per-header IL is already written as `.ours.json`, `main.go:218-228`). `depends[]` loads the index instead of re-parsing. `Dependency.Import` replaces the sibling-dir assumption in `qualifiedPrefix` (`emitnim.go:25-29`). Qt's own modules may keep running in-process, so no output changes.
7. **New behaviour, off for Qt at first.** Implicit constructors, exception catching, free functions, `#include <new>`, and `std.*` projections are each enabled in the new library configs. Turning one on for Qt is a separate "regenerate" PR whose output diff is the review.

## 3. C++ → C: what is translated today

### 3.1 Tallies (Qt 6.11.2: Core, Gui, Widgets, Network; 544 headers; 31,280 C functions emitted)

**Pass 2 blocks** come from `astTransformBlocklist` and from the inherited virtual and protected methods, counted once per class occurrence: **848**.

| Count | Rule (`config-allowlist.go`) | Top offending types |
|---:|---|---|
| 394 | `:880-882`, exact-name type list | `QStringView` 184, `QLatin1String` 88, `char32_t` 46, `char16_t` 16, `qfloat16` 14, `QUtf8StringView` 6, `QtMsgType` 4, `FILE` 4, `QPlatform*` 11, `QRhi*` 9 |
| 270 | `:623-627`, by-value use of a blocked class | `std::*` **166** (`std::pair` 28, `std::optional` 24, `std::chrono::*` 42, `std::reverse_iterator` 16, `std::filesystem::path` 15, `std::function` 14, `std::initializer_list` 10, `std::nullptr_t` 9, `std::unique_ptr` 3, …), `QPolygonF`/`QPolygon` 62 (they extend `QList<QPoint>`), `QKeyValueIterator` 12 |
| 48 | `:656-657`, `QBindable<…>` | `QBindable<int>` 15, `QBindable<bool>` 8, … |
| 30 | `:629-630`, function pointer | `void (*)(void *)`, `QTextStream (*)(QTextStream &)`, … |
| 25 + 11 + 3 | `:753-766`, out-parameter `QString*`, `QByteArray*`, `QFormLayout::ItemRole*` | |
| 18 | `:685-686`, `QSpan<…>` | `QSpan<char>`, `QSpan<uchar>`, `QSpan<std::byte>` |
| 7, 6, 5, 5, 4, 4, 3, 3, 2, 2, 2, 2, 1, 1 | other template prefixes and pointer rules: `QUrlTwoFlags`, `::DataPtr`, `FinalizeResultChar`, `QMultiMap`/`QMultiHash`, `StringResult`, `T**`, `QGenericMatrix`, `QExplicitlySharedDataPointer`, `EncodedData`, `QRgbaFloat`, xpm `char**`, `EulerAngles`, `QMap<QByteArray,…>`, `QSharedDataPointer`, `QPointer` | |

**Pass 1 skips** come from `clang2il.go` and are counted per declaration: **625**.

| Count | Reason |
|---:|---|
| 447 | rvalue reference anywhere in the signature (`clang2il.go:793`): 236 constructors (move constructors, `T&&` overloads) and 211 methods (move assignment, `&&` overloads) |
| 70 | public field of a blocked type (`std::` mostly) |
| 52 | `qt_check_for_QGADGET_macro` |
| 21 | receiver/member pattern (`QObject::connect(..., const char*)` and the like) |
| 14 | returns an int by reference (`QPoint::rx`, `QSize::rheight`) |
| 21 | named class or method rules (18), fields of blocked types (3) |

**Silent drops** happen in the clang filter, before the generator's own code sees the declaration. These are nodes located in the header being parsed, so the counts are approximate.

| Count | Kind | Effect |
|---:|---|---|
| 3,310 | `FunctionDecl` at file and namespace scope | Every free function and every non-member operator is gone (`qVersion`, `qHash`, `operator+(QPoint,QPoint)`, …) |
| 2,977 | `FriendDecl` | Hidden-friend operators are gone. Qt 6 moved comparisons there, so `QPoint` has **no** `==` and no `+` in the bindings, only `+=` and `-=` (checked in `gen_qpoint.h`). `emitcabi.go:1366-1372` still says "Qt 6.8 moved many operator== … By using infix syntax, either can be called", but the method it relies on no longer exists. |
| 1,027 | `FunctionTemplateDecl` | Member and free function templates |
| 1,007 | `ClassTemplateDecl` (315) and `ClassTemplate(Partial)SpecializationDecl` (692) | Class templates, and their specializations written in headers |
| 990 | `VarTemplateDecl`/`VarTemplate*` | Mostly type traits |
| 205 | `VarDecl` at namespace scope | Constants |
| 104 + 47 + 26 | `UsingShadowDecl`, `UsingDecl` and `ConstructorUsingShadowDecl` in classes | `using Base::f;` overloads and inherited constructors |
| 98 | `TypeAliasTemplateDecl` | |
| 16 | `LinkageSpecDecl` | `extern "C"` blocks |
| 961 + 106 | `CXXMethodDecl`/`Ctor`/`Dtor`/`Conversion` at file scope | Out-of-line definitions of declared members; harmless |

### 3.2 Inventory

Status values: **yes** means supported; **partial** means some forms; **silent** means dropped with no log line; **blocked** means dropped with a log line; **breaks** means it emits code that does not compile, or panics.

| Construct | Status | Evidence | How it could be translated |
|---|---|---|---|
| Classes, structs, public methods | yes | the bulk of the 31,280 functions | |
| Overloads | yes | `transformoverload.go:36-98`: renamed by parameter names, then types, then const | Names follow parameter names, so renaming a parameter in a header changes the C symbol (`LogosAPIClient_invokeRemoteMethod_objectName_methodName_arg1_arg2`). Worth a config switch "types first" for libraries that want a stable C ABI. |
| Default arguments | yes | `transformoptional.go`: one function per prefix (`lib__User_sum_a`, `_sum_a_b`). Virtual methods take all their parameters. | |
| References, `const T&` | yes / partial | Class types become pointers. `int&` returns are blocked (14). `const int&` parameters become `const int*` (seen as `BoxInt_set(BoxInt*, const int*)` in §4.3). | Pass `const T&` of a scalar by value. |
| rvalue references, move semantics | blocked | 447 | Bind a `T&&` parameter as "consumes the argument": the C side passes a pointer, and the wrapper does `std::move(*p)`. Move constructors are only needed for move-only types. |
| Enums, `enum class`, anonymous enums | yes | `clang2il.go:554-682`; the trial got `LogosModeEnum` with `Remote`/`Local`/`Mock` | Entries whose value is not a constant expression break (`processEnum` returns an error, which panics). |
| `QFlags<E>` | yes | `intermediate.go:65-87`, as int | |
| Nested types | yes | `Outer::Inner` becomes `Outer__Inner`, with the forward-declaration workaround macro (`emitcabi.go:912-921`); public only | |
| Namespaces | yes | They prefix names: `lib::User` becomes `lib__User` in C and `libUser` in Nim. Unnamed namespaces are skipped. | |
| Namespace aliases | silent | `clang2il.go:55-57` (TODO for Qt 6.8+) | |
| Member operators | yes | `SafeMethodName` (`intermediate.go:318-371`): `operatorPlusAssign`, `operatorSubscript`, `ToBool`. Assignments return void (`clang2il.go:772-777`). | |
| Non-member and hidden-friend operators | silent | 3,310 + 2,977 above | Emit `ns__Class_operatorEqual(a, b)` and attach it to the first parameter's class on the Nim side. |
| Free functions | silent | above; Logos `LogosModeConfig::setMode` and the five others | Emit them as `ns_name(...)` per header. Overloads go through the same renaming. |
| Static methods | yes | `Class::m(...)` | |
| Static data members, `constexpr` constants | blocked (logged as NOT IMPLEMENTED) | `counter` and `kMax` in the probe. Only `staticMetaObject` is special-cased. | A getter (and a setter if not const); constexpr values as Nim consts. |
| Public fields | partial | Getter and setter (`clang2il.go:438-503`). An array field panics, and unnamed or array types are skipped by string match. | Arrays: block, or a getter returning a pointer and length. |
| Virtual methods, subclassing | yes | `Virtual<Class>` with a vtable struct and vdata (`emitcabi.go:1144-1276`). The class needs a constructor in the AST (`intermediate.go:430-437`). | |
| Abstract classes and interfaces with no declared constructor | partial: callable, not subclassable | `LogosObject`, `PluginInterface`, `LogosProviderObject`, `lib::Pod`, `lib::detail::Hidden` get no `_new`, because clang declares implicit special members lazily. `definitionData.defaultCtor` says `{"exists":true,"needsImplicit":true}` (checked with clang 14 on a POD and on an abstract class). | Synthesize the implicit default constructor from `definitionData` (`Features.ImplicitCtors`). PODs become constructible, and interfaces such as `PluginInterface` become subclassable from Nim. |
| Blocked pure virtual | breaks | `VirtualLogosProviderObject` is abstract and the wrapper does not compile | If a pure virtual is blocked, the class is not subclassable. Alternatively, emit an override that aborts. |
| Protected members | yes (via subclass) | `*_protectedbase_*` friends; protected static non-virtuals are dropped (`clang2il.go:409-415`), protected operators too (`416-422`) | |
| Multiple inheritance | partial | C has `*_virtbase` with one out-pointer per base. Nim writes `# TODO Multiple inheritance` (`emitnim.go:1000-1002`). | |
| `using Base::f`, inheriting constructors | silent | 47 + 26 above | Treat `UsingShadowDecl` as importing the base overloads under the derived name. |
| Typedefs, `using X = Y` | yes | `KnownTypedefs`, resolved before blocking (`transformtypedefs.go`) | |
| Class templates used in signatures | partial: containers only | Containers are projected (§1b.2). Everything else is blocked by prefix (about 30 rules), or panics when used by value (`Box<int>`). | §4 |
| Function templates, member templates | silent | 1,027; Logos `LogosResult::getValue<T>()` | Pre-instantiation, with configured template arguments (§4). |
| `std::string`, `std::string_view` | blocked | `std::` prefix (`config-allowlist.go:695-703`, `185-187`); the Logos `std::runtime_error(const std::string&)` constructor | A `std.string` projection to `seaqt_string`, like `QByteArray`. |
| `std::vector`, `std::map`, `std::pair`, `std::optional` | blocked | 28 `std::pair`, 24 `std::optional` | Like `QList`/`QMap`/`QPair`. `std::optional<T>` becomes a value plus a `bool* has` out-flag, or a nullable heap copy. |
| `std::function` | blocked | 14 in Qt; **16 in the Logos SDK**, every async call and event subscription | Reuse the signal seam: `(intptr_t slot, void (*cb)(intptr_t, …), void (*release)(intptr_t))`. The wrapper builds a `std::function` from a lambda capturing a `std::shared_ptr<seaqt::release_callback>`. A shared pointer is needed because `std::function` must be copyable and `release_callback` is move-only. |
| `std::chrono::*` | blocked | 42 | `int64` count of the type's period |
| Smart pointers (`unique_ptr`, `shared_ptr`, `QSharedPointer`, `QScopedPointer`, `QPointer`) | blocked | `std::unique_ptr` 3 and `QPointer` 1 here; `QSharedPointer`/`QScopedPointer` by prefix | A `unique_ptr` return becomes an owned pointer (release). `shared_ptr` becomes an opaque handle class (pre-instantiated, §4). |
| Exceptions | silent and unsafe | Nothing is caught, and a throw through `extern "C"` into Nim is undefined behaviour or a terminate. Logos `LogosResult::getString()` throws `LogosResultException` when `!success`. | `Features.Exceptions: "catch"`: wrap non-`noexcept` calls in `try { } catch (const std::exception& e) { seaqt_set_error(e.what()); }` and return a zero value. Nim raises from `seaqt_take_error()`. |
| `noexcept` | yes | Parsed and carried into overrides (`clang2il.go:825-867`) | |
| Variadic C functions | breaks | `self->varargs(fmt, );` | Block. A `va_list` overload, where one exists, is bindable. |
| Variadic templates | silent | (templates) | |
| Function pointers | blocked | 30 | A C function-pointer type passed through as-is |
| Arrays (`char*[]`, `T[N]` fields) | blocked / breaks | xpm `char**` blocked; `int arr[4]` panics | |
| `inline` / `constexpr` functions | yes as members; silent as free functions | | free functions as above |
| `extern "C"` blocks | silent | 16 `LinkageSpecDecl` | Already C: re-export, or let the user include them |
| `char16_t`, `char32_t`, `wchar_t`, `qfloat16` | blocked | 77 | `uint16_t`, `uint32_t`, `wchar_t`, `_Float16` |
| `QStringView`, `QLatin1String`, `QUtf8StringView` | blocked | 278, the largest single group | As parameters, a view over the `QString` made from the UTF-8 input (exactly what `QAnyStringView` does at `emitcabi.go:295-306`). As returns, `.toString()`. Most have `QString` overloads, so this is high count but low value. |
| Platform conditionals | yes | `RequireCpp` quirks emit `#if` | |
| Deleted functions | yes | `isExplicitlyDeleted` | |
| Private and deleted destructors | yes | `CanDelete=false` | |

### 3.3 An order to work through them, by value

1. **Robustness first.** It is cheap and protects every new user:
   - block messages carry the rule and the type;
   - no panics (a by-value uninstantiated template, an array field, a non-constant enum value);
   - varargs blocked;
   - a pure virtual blocked ⇒ the class is not subclassable;
   - a cache key over content, flags and clang version;
   - a summary of the headers that failed to parse;
   - `#include <new>`.
2. **Implicit special members from `definitionData`.** POD structs become constructible, and interfaces such as the Logos SDK's `PluginInterface` and `LogosObject` become subclassable. A Nim Basecamp plugin needs this.
3. **`std::function` parameters** through the existing callback seam. This is the Logos SDK's whole async and event surface (16 methods), plus 14 in Qt.
4. **`std::string`, `vector`, `pair`, `optional` and `chrono`.** `std::` accounts for 166 of the 270 by-value blocks in Qt, and for most of any plain C++ library.
5. **Free functions and hidden-friend operators.** There are thousands of declarations, including the `QPoint ==` and `+` regression.
6. **Exceptions → error.** Without it, a plain C++ library is not safe to call; with Qt the issue is rare.
7. **Template pre-instantiation (§4).** `QBindable<T>` (48), `QSpan<T>` (18), and library-specific handles.
8. **Static data members and constants; `using`-declarations and inheriting constructors.**
9. **rvalue overloads.** 447 skips, but most duplicate a `const&` overload. The value is in move-only types.
10. **Views and char types** (`QStringView`, `char16_t`, …). This has the largest count and the lowest marginal value.

## 4. Templates by pre-instantiation

### 4.1 Today

- **The filter.** It drops every template declaration before the generator sees it (`clangfilter.go:62-68`, `136-147`). The comment there says: "Template stuff probably can't be supported in the binding since we would need to link a concrete instantiation for each type in the CABI".
- **Containers.** Template specializations that appear in signatures are recognised by string prefix on clang's `qualType` (`intermediate.go:116-198`). They are *projected*: `QList<T>` is converted element by element to and from `seaqt_array`, and `QMap` and `QHash` to `seaqt_map`. They are never bound as classes.
- **Everything else** is blocked by prefix (`config-allowlist.go:632-693`), or panics when it is used by value.

Containers should stay projections: a Nim `seq` is the right type for a `QList<int>`. Pre-instantiation is for templates that are *objects*: `QBindable<int>`, `QSpan<char>`, `QFuture<void>`, `QQmlListProperty<QObject>`, `std::shared_ptr<Foo>`, and a library's own `Box<T>`.

### 4.2 Design

**Where instantiations are declared.** In the library configuration:

```json
"instantiate": [
  {"cpp": "lib::Box<int>", "name": "BoxInt", "include": ["boxlib.h"]},
  {"cpp": "QBindable<int>", "name": "QBindableInt", "include": ["QBindable"], "skipMethods": ["makeBinding"]}
]
```

`name` is the C and Nim name. If it is omitted, it is derived with the existing overload mangler's scheme (`transformoverload.go:8-31`: `<` → `Of`, `,` → `_`, so `QMap<QString, int>` becomes `QMapOfQString_int`). An explicit name is better for a public C ABI.

**How clang is made to emit the instantiated AST.** The generator writes one header per library:

```cpp
#pragma once
#include <boxlib.h>
#ifdef SEAQT_GEN_PARSE
extern template class lib::Box<int>;
#endif
```

It parses this header like any other, with `-DSEAQT_GEN_PARSE`. I checked the following with clang 14:

- **Declaration, not definition.** An explicit instantiation *declaration* (`extern template class X<T>;`) makes clang emit a **file-level `ClassTemplateSpecializationDecl` located on that line of the generated header**. Its member declarations carry the substituted types: `get` is `int () const`, `set` is `void (const int &)`, plus the implicit copy and move constructors.
- **Member definitions stay uninstantiated.** A member that would not compile for `T` (`bool eq(const T&)` with a `T` that has no `==`) is not an error at parse time.
- **The alternatives are worse.** An explicit instantiation *definition* (`template class X<T>;`) produces the same node, but instantiates every member definition, so that case fails at parse time. Implicit instantiation (`sizeof(X<T>)`) produces the members too, but the node sits inside the `ClassTemplateDecl` in the library's header, not at a known line of ours.

The `#ifdef` matters. Outside the parse, the wrapper `.cpp` includes the same header without the `extern template`, so ordinary implicit instantiation happens where the wrapper uses a member. With `extern template` left in, the members that are not inline would be missing at link time unless the library ships its own explicit instantiation.

**How the node is identified.** It carries `name: "Box"`, with the arguments in `TemplateArgument` children. Three ways to name it, from simplest to most general:

- the line number in our generated header maps back to the configured entry (the prototype uses this);
- the node's `id` equals one listed under the `ClassTemplateDecl`, whose namespace path is known;
- `parentDeclContextId` gives the enclosing namespace.

**How it is named in C, Nim and C++.** `CppClass.ClassName` keeps the C++ spelling (`lib::Box<int>`), so every emitted C++ expression is valid as-is: `new lib::Box<int>(…)`, `self->get()`, `lib::Box<int>::make(v)`, and `class VirtualBoxInt : public lib::Box<int>`. Only `cabiClassName` maps it to the configured name. The existing inner-class forward-declaration workaround (`emitcabi.go:912-921`) handles the C header unchanged: `typedef lib::Box<int> BoxInt;` under `WORKAROUND_INNER_CLASS_DEFINITION_BoxInt`, and `class BoxInt;` otherwise. Longer term, `CppClass` should carry `CppName` and `CName` separately, instead of `cabiClassName` deriving one from the other.

**Spelling normalization.** Clang prints the same type several ways in one specialization:

- `make`'s return type is `Box<int>`, unqualified, because it was written that way inside `namespace lib`;
- the implicit copy constructor's parameter is `const lib::Box<int> &`;
- `std::string` comes out as `std::basic_string<char>` inside the members, while the `TypeAliasDecl` keeps the sugar.

Function types carry no `desugaredQualType`. The generator reads only `qualType` strings, so each instantiation needs every spelling mapped to it, at least the qualified and the unqualified one. The prototype registers the unqualified spelling as a typedef of the qualified one. The robust fix is to take parameter types from the `ParmVarDecl` nodes, whose `type` carries `desugaredQualType` wherever the written type is sugar (a typedef, a substituted template parameter), rather than string-splitting the function type (`clang2il.go:788-896`). That would also fix clang ≥ 16, which prints nested types unqualified and makes the generator panic (muster's `seaqt-ro.nix` pins clang 14 for that reason).

**Members that do not compile for a given T.** They are found when the wrapper is compiled, not when it is parsed. The prototype's `BoxNoEq_eq` was emitted, then failed in `gen_seaqt_instantiations.cpp` with "invalid operands to binary expression". Options, cheapest first:

- per-instantiation `skipMethods` in the config;
- a C++20 `requires` guard per wrapper, which needs `-std=c++20`;
- a trial compile per method. That is too slow.

### 4.3 Prototype: branch `logos-sdk-trial`, commit `c3cb73a8`

About 120 lines: `cmd/genbindings/instantiate_trial.go`, plus `// trial` hunks in `clangfilter.go`, `clang2il.go`, `emitcabi.go` and `config-libraries.go`. The template is `lib::Box<T>`, and `lib::Holder` uses `Box<int>` by value.

- **Parsing.** `SEAQT_GEN_INSTANTIATE="BoxInt=lib::Box<int>"` parses the generated header and binds `BoxInt_new`, `BoxInt_new_v`, `BoxInt_new_from`, `BoxInt_get`, `BoxInt_set`, `BoxInt_eq`, `BoxInt_make`, `BoxInt_operatorAssign` and `BoxInt_delete`.
- **Use in other classes.** `lib::Holder`'s members resolve to it: `BoxInt* lib__Holder_box(const lib__Holder*)` and `lib__Holder_setBox(…, BoxInt*)`. Without the instantiation, the same header panics the run.
- **A Nim program runs.** It prints `BoxInt.get: 42` and `Holder.box().get(): 7` (`trial/run-templates.sh`).
- **The failure case.** `BoxNoEq=lib::Box<lib::NoEq>` parses and emits, then fails to compile its `eq` wrapper, as described above.
- **No change for Qt.** The filter changes keep file-level `ClassTemplateSpecializationDecl`s. QtCore, QtGui, QtWidgets and QtNetwork regenerated with the prototype binary, from a cold cache, gave output byte-identical to master's.

## 5. Trial on the Logos C++ SDK

**Branch.** `logos-sdk-trial` in worktree `~/seaqt-upstream/wt/logos-sdk-trial`, local, not pushed: commit `fe864e03` is this trial, `c3cb73a8` the template prototype of §4.3. Neither is meant for merge. The SDK is `~/logos-cpp-sdk` at `0122155`. It is a hack in `config-libraries.go`: after the Qt modules, a library "LogosSdk" is built from 9 headers, depends on QtCore by being generated in the same run, and takes cflags `-I sdk/cpp -I sdk/core`. `trial/run.sh` reproduces everything: it generates, patches the emitted `logossdk_pkg.nim` (the two lines a config would supply), builds and runs the demo.

**What parses.**

- All 9 headers parse without a clang error: `logos_api.h`, `token_manager.h`, `logos_api_client.h`, `logos_object.h`, `logos_types.h`, `logos_mode.h`, `logos_api_provider.h`, `logos_provider_object.h` and `core/interface.h`.
- The SDK is Qt-based: `LogosAPI`, `TokenManager`, `LogosAPIClient` and `LogosAPIProvider` are `QObject`s, and the API is `QString`/`QVariant`/`QVariantList`. So the Qt projections and the QtCore type state do almost all the work. The real config question is the dependency on QtCore (§2.3).

**What binds: 229 C functions.**

- **The token path.** `LogosAPI_getTokenManager(const LogosAPI*)`, `LogosAPI_getClient`, `LogosAPI_getProvider`. `TokenManager_instance`, `saveToken`, `getToken`, `hasToken`, `getTokenKeys`, and the signals `connect_tokenSaved`/`Removed`/`AllTokensCleared`. `LogosAPIClient_getToken`, `informModuleToken`, `isConnected`, and the 13 C entry points of the 6 `invokeRemoteMethod` overloads (`QVariant` arguments, default `Timeout` expanded). `PluginInterface_logosAPI` and `setLogosAPI` (the public field).
- **The provider side.** `LogosObject` and `LogosProviderBase` (`callMethod`, `emitEvent` via `protectedbase`, the `onInit` virtual).
- **The rest.** `LogosResult`'s non-template getters, `Timeout`, and `enum class LogosMode`.

**The demo.** `trial/token_demo.nim`, built with `nim c` against a `liblogos_sdk.a` from the same checkout and Qt:

```nim
let app = QCoreApplication.create()
let tm = TokenManager.instance()
tm.saveToken("capability_module", "tok-123")
let api = LogosAPI.create("muster_ui")
let viaApi = api.getTokenManager()          # non-virtual, out-of-line accessor
doAssert viaApi.h == tm.h
echo "token via LogosAPI*: ", viaApi.getToken("capability_module")
```

It prints `token via LogosAPI*: tok-123` and `keys: @["capability_module"]`. This is exactly the accessor muster could not reach from Nim in T4b.

**What does not compile.** `gen_logos_provider_object.cpp`: `VirtualLogosProviderObject` stays abstract, because its pure virtual `setEventListener(std::function<…>)` was blocked (§1c). The other 8 wrapper `.cpp` files compile.

**What is blocked (17, logged).**

- 12 `invokeRemoteMethodAsync` entry points (6 overloads, with and without the timeout), `LogosAPIClient::onEvent`, `LogosObject::onEvent` and two `setEventListener`: all of them take `std::function`.
- `LogosResultException(const std::string&)`.

**What is silently dropped.**

- The namespace `LogosModeConfig` (6 inline free functions, `setMode` among them).
- `operator<<`/`>>` for `LogosResult`.
- `LogosResult::getValue<T>`/`getError<T>` (templates).

**What cannot be created or implemented from Nim.**

- `LogosResult` has only a copy constructor bound: its default constructor is implicit and undeclared.
- `PluginInterface`, `LogosObject` and `LogosProviderObject` cannot be subclassed: they are abstract with no declared constructor (§3.2).
- A Nim implementation of the plugin interfaces needs implicit constructors, and for `class X : public QObject, public PluginInterface` it would also need a subclass with two bases, which the generator does not do.

**Generic gaps that showed up.**

- The emitted package knows only `pkg-config Qt6Core`, with no SDK include path or library (§2.3 `cflags`/`libs`).
- Forwarders `timeout.nim`, `logosapi.nim`, … landed in Qt's flat `seaqt/` dir.
- Logos classes get no per-class include: the `Q` prefix rule does not apply to them. The header's own include covers this.

**What this means for Basecamp's `ui-host`.** `ui-host` links the SDK statically and exports none of its symbols (muster T4b). A Nim plugin built from these bindings therefore links its own copy of `liblogos_sdk.a`. Two consequences:

- **Use the host's object.** `TokenManager::instance()` called from the plugin is the *plugin's* singleton, which is empty. The token must be read through the `LogosAPI*` the host passes to `initLogos`. `getTokenManager()` returns the host's object from the host's field (`logos_api.cpp:51-54`), and `TokenManager::getToken` then runs the plugin's copy of the code on the host's object.
- **Layout coupling.** That is sound only while the plugin's SDK revision and Qt match `ui-host`'s object layout (`QHash` + `QMutex` members). A C++ plugin carries the same coupling today. The two `ui-host` changes muster asked for, a C-ABI token handoff and a plugin naming its remote object, remain the cleaner route. Generated bindings make the route that exists today usable from Nim without hand-written C++.

## 6. A plan in PR-sized steps

| # | PR | Output change for Qt |
|---|---|---|
| 1 | Block messages name the rule and the type, plus an end-of-run summary: blocks by rule, headers that failed to parse, dropped node kinds. This is the instrumentation behind §3. | none (logs only) |
| 2 | Robustness. Replace the two panics with blocks, block varargs, and make a class with a blocked pure virtual non-subclassable. Key the AST cache on content, cflags and clang version. | none expected; golden-checked |
| 3 | Golden harness, `make golden` over a module subset. Also land the module filter, if not merged already. | none |
| 4 | `Library`/`Module` structs in Go; buildQt5/6 become data; the literal `QtCore`/`qobject.h`/`qvariant.h` checks move into fields (steps 1-2). | none |
| 5 | Allowlist and quirks as data; JSON loader; `-config`; embedded `qt5.json`/`qt6.json` (step 3) | none |
| 6 | Feature gates: `qobject` (all, derived or off), version gates, argc/argv; projection sets named (steps 4-5). | none |
| 7 | Dependencies: a per-module type index, `depends[]`, a Nim import root, per-module `cflags`/`libs` in `*_pkg.nim`, forwarders optional. A test library under `testdata/` (the §3 probe header, cut down) whose generated wrappers CI compiles. | none |
| 8 | Implicit constructors from `definitionData`; `#include <new>`. | yes, reviewed as a diff, or off for Qt at first |
| 9 | `std.function` via the callback seam, then `std.string`/`vector`/`optional`/`pair`/`chrono`. | none until Qt opts in |
| 10 | Free functions and hidden-friend operators. | yes, adds `QPoint ==` and the rest |
| 11 | Exceptions: `catch` mode with an error slot | none until Qt opts in |
| 12 | Template pre-instantiation (§4), with types taken from `ParmVarDecl` instead of split `qualType` strings. That also removes the clang 14 pin. | none |

PRs 1-3 are independent, and each is useful on its own. From PR 4 onwards, each step depends on the previous one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

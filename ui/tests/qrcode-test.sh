#!/usr/bin/env bash
# QrCode.qml decodes back to what it encodes (exo-dcc.5). Renders each case of
# qrcode-test.qml offscreen and reads every PNG with zbarimg. No display, no runner.
#   ui/tests/qrcode-test.sh
# Qt and zbar come from nixpkgs (QrCode.qml imports only QtQuick, so any Qt 6 does).
set -euo pipefail
cd "$(dirname "$0")"
store() { nix build --no-link --print-out-paths "nixpkgs#$1" 2>/dev/null | grep -vE -- '-(man|dev|doc|lib)$' | head -1; }
QT_DECL=$(store qt6.qtdeclarative)
QT_BASE=$(store qt6.qtbase)
ZBAR=$(store zbar)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  QT_PLUGIN_PATH="$QT_BASE/lib/qt-6/plugins" QML_IMPORT_PATH="$QT_DECL/lib/qt-6/qml" \
  timeout 180 "$QT_DECL/bin/qml" qrcode-test.qml -- "$OUT" 2>&1 | grep -E 'CASE|DONE|rror' || true
PATH="$ZBAR/bin:$PATH" python3 - "$OUT" <<'EOF'
import os, subprocess, sys
out = sys.argv[1]
cases = ["a", "hello",
         "monero:77Rv8w4ExbGHE8kgVJt93zPZsiSfj7qDPC4wsg9cTRGhAvbnGNbUNTwWMUs2RfYQ1h1YHo2KiJvXgFbHaLz7mtCbM5NNoWv?tx_amount=0.123456789012"]
cases += ["x" * k for k in (14, 15, 26, 27, 122, 123, 152, 180, 213, 250, 331, 450, 600, 858, 1000, 1500, 2000, 2331)]
cases += ["Ünïcödé ✓ 🙂 monero", "0123456789" * 37, "x" * 2332]
bad = 0
for i, c in enumerate(cases):
    f = os.path.join(out, f"c{i}.png")
    fits = len(c.encode()) <= 2331
    if not os.path.exists(f):
        ok = not fits
        print(f"{'ok  ' if ok else 'FAIL'} case {i} ({len(c.encode())} bytes): no code" + ("" if ok else " drawn"))
        bad += not ok
        continue
    got = subprocess.run(["zbarimg", "-q", "--raw", "-Sbinary", f], capture_output=True).stdout.rstrip(b"\n")
    ok = fits and got == c.encode()
    print(f"{'ok  ' if ok else 'FAIL'} case {i} ({len(c.encode())} bytes)" + ("" if ok else f": read back {got[:40]!r}"))
    bad += not ok
print("QrCode decode-back:", "PASS" if bad == 0 else f"{bad} FAILED")
sys.exit(1 if bad else 0)
EOF

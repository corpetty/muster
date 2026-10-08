import QtQuick
import "../src/qml" as M

// QrCode.qml, decoded back (exo-dcc.5): one PNG per case in $QR_OUT, which qrcode-test.sh
// reads with zbarimg and compares with what was encoded. The cases span versions 1–40 at
// level M (each capacity edge: 14/15, 26/27, 122/123, 2331 bytes), the shape of a real
// monero: link, non-ASCII text, and one byte too many (no code at all).
Item {
    id: h
    width: 800
    height: 800
    readonly property string out: Qt.application.arguments[Qt.application.arguments.length - 1]
    readonly property var cases: [
        "a", "hello",
        "monero:77Rv8w4ExbGHE8kgVJt93zPZsiSfj7qDPC4wsg9cTRGhAvbnGNbUNTwWMUs2RfYQ1h1YHo2KiJvXgFbHaLz7mtCbM5NNoWv?tx_amount=0.123456789012",
        "x".repeat(14), "x".repeat(15), "x".repeat(26), "x".repeat(27), "x".repeat(122), "x".repeat(123),
        "x".repeat(152), "x".repeat(180), "x".repeat(213), "x".repeat(250), "x".repeat(331), "x".repeat(450),
        "x".repeat(600), "x".repeat(858), "x".repeat(1000), "x".repeat(1500), "x".repeat(2000), "x".repeat(2331),
        "Ünïcödé ✓ 🙂 monero", "0123456789".repeat(37), "x".repeat(2332)]
    property int i: 0
    property bool shown: false
    M.QrCode { id: q; width: 800; height: 800 }
    Timer {
        interval: 150
        repeat: true
        running: true
        onTriggered: {
            if (!h.shown) {
                if (h.i >= h.cases.length) { console.warn("DONE"); Qt.quit(); return; }
                q.text = h.cases[h.i];
                h.shown = true;
                return;
            }
            var idx = h.i;
            console.warn("CASE " + idx + " version=" + (q.matrix ? q.matrix.version : 0) + " bytes=" + h.cases[idx].length);
            if (q.matrix) q.grabToImage(function (r) { r.saveToFile(h.out + "/c" + idx + ".png"); });
            h.i++;
            h.shown = false;
        }
    }
}

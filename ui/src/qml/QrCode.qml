import QtQuick

// A QR code of `text`, drawn on a Canvas, in pure QML/JS (exo-dcc.5): neither the repo
// nor Logos.Controls has one, and a native encoder (the Monero wallet app links Nayuki's
// qrcodegen in C++) would be a new native dependency for a view module.
//
// The encoder follows Project Nayuki's QR Code generator (MIT License, Copyright (c)
// Project Nayuki, https://www.nayuki.io/page/qr-code-generator-library): byte mode only,
// error correction level M, the smallest version (1–40) that holds the text, and the
// mask with the lowest penalty. It is checked by decoding what it draws (zbarimg) in the
// offscreen harness, for lengths across versions 1–40.
//
// Always dark on light, whatever the theme, with the 4-module quiet zone a scanner needs.
// `size` is 0 when the text does not fit (more than 2331 bytes at level M).
Item {
    id: qr

    property string text: ""
    // the modules, row by row (true = dark), and their count per side; 0 = nothing drawn
    readonly property var matrix: qr.encode(qr.text)
    readonly property int size: qr.matrix ? qr.matrix.size : 0
    property color dark: "#000000"
    property color light: "#ffffff"

    implicitWidth: 200
    implicitHeight: 200

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Immediate
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var m = qr.matrix;
            if (!m) return;
            var n = m.size + 8;                       // 4 light modules on every side
            var cell = Math.floor(Math.min(width, height) / n);
            if (cell < 1) return;
            var off = Math.floor((Math.min(width, height) - cell * n) / 2);
            ctx.fillStyle = qr.light;
            ctx.fillRect(0, 0, width, height);
            ctx.fillStyle = qr.dark;
            for (var y = 0; y < m.size; ++y)
                for (var x = 0; x < m.size; ++x)
                    if (m.modules[y * m.size + x])
                        ctx.fillRect(off + (x + 4) * cell, off + (y + 4) * cell, cell, cell);
        }
    }
    onMatrixChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()

    // ── the encoder ────────────────────────────────────────────────────────────────
    // Level M's error-correction codewords per block and number of blocks, by version
    // (index 0 unused) — ISO/IEC 18004 Table 9, as Nayuki tabulates them.
    readonly property var eccPerBlock: [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28,
        26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
    readonly property var numBlocks: [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17,
        17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]

    function utf8(s) {
        var out = [];
        for (var i = 0; i < s.length; ++i) {
            var c = s.charCodeAt(i);
            if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
                var d = s.charCodeAt(i + 1);
                if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); ++i; }
            }
            if (c < 0x80) out.push(c);
            else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
            else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return out;
    }
    function rawModules(ver) {
        var r = (16 * ver + 128) * ver + 64;
        if (ver >= 2) {
            var na = Math.floor(ver / 7) + 2;
            r -= (25 * na - 10) * na - 55;
            if (ver >= 7) r -= 36;
        }
        return r;
    }
    function dataCodewords(ver) {
        return Math.floor(qr.rawModules(ver) / 8) - qr.eccPerBlock[ver] * qr.numBlocks[ver];
    }
    function gfMul(x, y) {
        var z = 0;
        for (var i = 7; i >= 0; --i) {
            z = (z << 1) ^ ((z >>> 7) * 0x11d);
            z ^= ((y >>> i) & 1) * x;
        }
        return z;
    }
    function rsDivisor(degree) {
        var r = [];
        for (var i = 0; i < degree - 1; ++i) r.push(0);
        r.push(1);
        var root = 1;
        for (var k = 0; k < degree; ++k) {
            for (var j = 0; j < r.length; ++j) {
                r[j] = qr.gfMul(r[j], root);
                if (j + 1 < r.length) r[j] ^= r[j + 1];
            }
            root = qr.gfMul(root, 0x02);
        }
        return r;
    }
    function rsRemainder(data, div) {
        var r = div.map(function () { return 0; });
        for (var i = 0; i < data.length; ++i) {
            var f = data[i] ^ r.shift();
            r.push(0);
            for (var j = 0; j < div.length; ++j) r[j] ^= qr.gfMul(div[j], f);
        }
        return r;
    }
    function alignPositions(ver) {
        if (ver === 1) return [];
        var na = Math.floor(ver / 7) + 2;
        var step = Math.floor((ver * 8 + na * 3 + 5) / (na * 4 - 4)) * 2;
        var out = [6];
        for (var pos = ver * 4 + 17 - 7; out.length < na; pos -= step) out.splice(1, 0, pos);
        return out;
    }

    function encode(text) {
        if (text === undefined || text === null || String(text).length === 0) return null;
        var bytes = qr.utf8(String(text));
        // the smallest version whose capacity holds mode + count + data
        var ver = 0;
        for (var v = 1; v <= 40; ++v) {
            var bits = 4 + (v <= 9 ? 8 : 16) + 8 * bytes.length;
            if (bits <= qr.dataCodewords(v) * 8) { ver = v; break; }
        }
        if (ver === 0) return null;
        var cap = qr.dataCodewords(ver);

        // the data bits: byte mode, the count, the bytes, a terminator, then pad bytes
        var bb = [];
        function put(val, len) { for (var i = len - 1; i >= 0; --i) bb.push((val >>> i) & 1); }
        put(4, 4);
        put(bytes.length, ver <= 9 ? 8 : 16);
        for (var b = 0; b < bytes.length; ++b) put(bytes[b], 8);
        put(0, Math.min(4, cap * 8 - bb.length));
        put(0, (8 - bb.length % 8) % 8);
        for (var pad = 0xec; bb.length < cap * 8; pad ^= 0xec ^ 0x11) put(pad, 8);
        var data = [];
        for (var k = 0; k < bb.length; k += 8) {
            var octet = 0;
            for (var t = 0; t < 8; ++t) octet = (octet << 1) | bb[k + t];
            data.push(octet);
        }

        // error correction per block, then the blocks interleaved
        var nb = qr.numBlocks[ver], eccLen = qr.eccPerBlock[ver];
        var raw = Math.floor(qr.rawModules(ver) / 8);
        var nShort = nb - raw % nb, shortLen = Math.floor(raw / nb);
        var div = qr.rsDivisor(eccLen);
        var blocks = [];
        for (var i = 0, off = 0; i < nb; ++i) {
            var dat = data.slice(off, off + shortLen - eccLen + (i < nShort ? 0 : 1));
            off += dat.length;
            var ecc = qr.rsRemainder(dat, div);
            if (i < nShort) dat.push(0);
            blocks.push(dat.concat(ecc));
        }
        var cw = [];
        for (var c = 0; c < blocks[0].length; ++c)
            for (var j = 0; j < blocks.length; ++j)
                if (c !== shortLen - eccLen || j >= nShort) cw.push(blocks[j][c]);

        // the function patterns
        var n = ver * 4 + 17;
        var mod = [], fn = [];
        for (var z = 0; z < n * n; ++z) { mod.push(false); fn.push(false); }
        function setF(x, y, dark) { mod[y * n + x] = dark; fn[y * n + x] = true; }
        for (var q = 0; q < n; ++q) { setF(6, q, q % 2 === 0); setF(q, 6, q % 2 === 0); }
        function finder(cx, cy) {
            for (var dy = -4; dy <= 4; ++dy)
                for (var dx = -4; dx <= 4; ++dx) {
                    var d = Math.max(Math.abs(dx), Math.abs(dy)), xx = cx + dx, yy = cy + dy;
                    if (xx >= 0 && xx < n && yy >= 0 && yy < n) setF(xx, yy, d !== 2 && d !== 4);
                }
        }
        finder(3, 3); finder(n - 4, 3); finder(3, n - 4);
        var ap = qr.alignPositions(ver);
        for (var ai = 0; ai < ap.length; ++ai)
            for (var aj = 0; aj < ap.length; ++aj) {
                if ((ai === 0 && aj === 0) || (ai === 0 && aj === ap.length - 1) || (ai === ap.length - 1 && aj === 0))
                    continue;
                for (var ey = -2; ey <= 2; ++ey)
                    for (var ex = -2; ex <= 2; ++ex)
                        setF(ap[ai] + ex, ap[aj] + ey, Math.max(Math.abs(ex), Math.abs(ey)) !== 1);
            }
        function formatBits(mask) {
            var d = (0 << 3) | mask;            // level M's format bits are 00
            var rem = d;
            for (var i = 0; i < 10; ++i) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
            var bits = ((d << 10) | rem) ^ 0x5412;
            function bit(i) { return ((bits >>> i) & 1) !== 0; }
            for (var a = 0; a <= 5; ++a) setF(8, a, bit(a));
            setF(8, 7, bit(6)); setF(8, 8, bit(7)); setF(7, 8, bit(8));
            for (var b2 = 9; b2 < 15; ++b2) setF(14 - b2, 8, bit(b2));
            for (var c2 = 0; c2 < 8; ++c2) setF(n - 1 - c2, 8, bit(c2));
            for (var d2 = 8; d2 < 15; ++d2) setF(8, n - 15 + d2, bit(d2));
            setF(8, n - 8, true);               // the dark module
        }
        formatBits(0);
        if (ver >= 7) {
            var rem7 = ver;
            for (var r7 = 0; r7 < 12; ++r7) rem7 = (rem7 << 1) ^ ((rem7 >>> 11) * 0x1f25);
            var vbits = (ver << 12) | rem7;
            for (var vi = 0; vi < 18; ++vi) {
                var vb = ((vbits >>> vi) & 1) !== 0, va = n - 11 + vi % 3, vc = Math.floor(vi / 3);
                setF(va, vc, vb); setF(vc, va, vb);
            }
        }

        // the codewords, in the zigzag
        var bi = 0;
        for (var right = n - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (var vert = 0; vert < n; ++vert)
                for (var jj = 0; jj < 2; ++jj) {
                    var x = right - jj;
                    var up = ((right + 1) & 2) === 0;
                    var y = up ? n - 1 - vert : vert;
                    if (!fn[y * n + x] && bi < cw.length * 8) {
                        mod[y * n + x] = ((cw[bi >>> 3] >>> (7 - (bi & 7))) & 1) !== 0;
                        ++bi;
                    }
                }
        }

        // the mask with the lowest penalty
        function maskAt(m, x, y) {
            switch (m) {
            case 0: return (x + y) % 2 === 0;
            case 1: return y % 2 === 0;
            case 2: return x % 3 === 0;
            case 3: return (x + y) % 3 === 0;
            case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
            case 5: return x * y % 2 + x * y % 3 === 0;
            case 6: return (x * y % 2 + x * y % 3) % 2 === 0;
            default: return ((x + y) % 2 + x * y % 3) % 2 === 0;
            }
        }
        function applyMask(m) {
            for (var y = 0; y < n; ++y)
                for (var x = 0; x < n; ++x)
                    if (!fn[y * n + x] && maskAt(m, x, y)) mod[y * n + x] = !mod[y * n + x];
        }
        function penalty() {
            var p = 0, dark = 0;
            function at(x, y) { return mod[y * n + x]; }
            // runs of five or more alike, and the 1:1:3:1:1 finder-like pattern, in rows and columns
            for (var pass = 0; pass < 2; ++pass)
                for (var a = 0; a < n; ++a) {
                    var run = 0, prev = null, line = [];
                    for (var b = 0; b < n; ++b) {
                        var cur = pass === 0 ? at(b, a) : at(a, b);
                        line.push(cur);
                        if (cur === prev) { ++run; if (run === 5) p += 3; else if (run > 5) p += 1; }
                        else { run = 1; prev = cur; }
                    }
                    for (var s = 0; s + 7 <= n; ++s)
                        if (line[s] && !line[s + 1] && line[s + 2] && line[s + 3] && line[s + 4] && !line[s + 5] && line[s + 6]) {
                            var before = true, after = true;
                            for (var w = 1; w <= 4; ++w) {
                                if (s - w >= 0 && line[s - w]) before = false;
                                if (s + 6 + w < n && line[s + 6 + w]) after = false;
                            }
                            if (before || after) p += 40;
                        }
                }
            // 2×2 blocks of one colour
            for (var by = 0; by < n - 1; ++by)
                for (var bx = 0; bx < n - 1; ++bx) {
                    var cc = at(bx, by);
                    if (cc === at(bx + 1, by) && cc === at(bx, by + 1) && cc === at(bx + 1, by + 1)) p += 3;
                }
            // the balance of dark and light
            for (var e = 0; e < n * n; ++e) if (mod[e]) ++dark;
            var total = n * n;
            p += (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
            return p;
        }
        var best = 0, bestP = -1;
        for (var mk = 0; mk < 8; ++mk) {
            applyMask(mk);
            formatBits(mk);
            var pen = penalty();
            if (bestP < 0 || pen < bestP) { best = mk; bestP = pen; }
            applyMask(mk);                      // XOR again: undo
        }
        applyMask(best);
        formatBits(best);
        return { size: n, version: ver, mask: best, modules: mod };
    }
}

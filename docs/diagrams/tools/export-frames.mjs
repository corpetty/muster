#!/usr/bin/env node
/**
 * Export each view of an interactive substrate as a standalone static SVG.
 *
 * Why this exists (../README.md §3.2): forum software routinely strips <script>,
 * so the interactive page has to be hosted and the post embeds an image. Keeping
 * those as two hand-made artefacts guarantees they drift. Here the substrate is
 * the source and the frames are generated, so a view can only be wrong in one
 * place.
 *
 *   node tools/export-frames.mjs [substrate-stack.html]
 *
 * No dependencies. It reads three things straight out of the substrate:
 *
 *   1. the <svg> element,
 *   2. the design tokens declared on `.bc, .bc-svg`,
 *   3. the VIEWS array from <script type="application/json" id="bc-views">,
 *
 * then replays the same highlight-and-route logic the page runs, and writes the
 * result with the stylesheet inlined.
 *
 * Two transforms make the output survive renderers weaker than a browser:
 *
 *   · `var(--x)` is resolved to its literal value. Not a drift risk — the values
 *     are read from the substrate, not restated here.
 *   · Dimming is baked into an explicit `bc-dim` class rather than left to
 *     `:not([data-view="overview"])`, because librsvg's selector support is
 *     narrower than a browser's and a silently-unstyled frame looks fine right
 *     up until someone publishes it.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIAGRAMS = resolve(HERE, "..");

/**
 * An arrow that crosses out of the device gets the outside accent. Which nodes
 * those are is read from the substrate — any node carrying `bc-node-out` — not
 * from a list here, so a second substrate does not have to be known about.
 */
const OUTWARD_CLASS = "bc-node-out";

const die = (msg) => {
  console.error(`export-frames: ${msg}`);
  process.exit(1);
};

/* ── read the substrate ─────────────────────────────────────────────── */

function parse(html, file) {
  const svg = html.match(/<svg class="bc-svg"[\s\S]*?<\/svg>/);
  if (!svg) die(`${file}: no <svg class="bc-svg"> found`);

  const viewsBlock = html.match(
    /<script type="application\/json" id="bc-views">([\s\S]*?)<\/script>/
  );
  if (!viewsBlock) die(`${file}: no <script id="bc-views"> found`);

  // Every <style> block after the first (the first styles the page chrome,
  // which an exported frame does not have).
  const styles = [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]);
  if (styles.length < 2) die(`${file}: expected a page <style> and a diagram <style>`);

  return { svg: svg[0], views: JSON.parse(viewsBlock[1]), css: styles.slice(1).join("\n") };
}

/** Design tokens, read from the substrate so the frames cannot drift from it. */
function tokens(css) {
  const block = css.match(/\.bc,\s*\.bc-svg\s*\{([\s\S]*?)\}/);
  if (!block) die("no `.bc, .bc-svg` token block to read colours from");
  const out = {};
  for (const m of block[1].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    out[m[1]] = m[2].trim();
  }
  return out;
}

/** Resolve var(--x) to literals, repeatedly — tokens may reference tokens. */
function flatten(css, vars) {
  let out = css;
  for (let pass = 0; pass < 5 && /var\(/.test(out); pass++) {
    out = out.replace(/var\((--[\w-]+)(?:\s*,\s*([^()]*))?\)/g, (whole, name, fallback) =>
      vars[name] ?? (fallback !== undefined ? fallback.trim() : whole)
    );
  }
  return out;
}

/**
 * Node geometry, from each `<g … data-id="…">`'s first <rect>.
 *
 * Attributes are read one at a time rather than as one positional pattern:
 * `<rect>` here appears both as `x=… y=…` and as `class=… x=… y=…`, and a
 * single ordered pattern silently matches neither.
 */
function geometry(svg) {
  const boxes = {};
  for (const m of svg.matchAll(/<g class="([^"]*)" data-id="([^"]+)"\s*>([\s\S]*?)<\/g>/g)) {
    const [, cls, id, inner] = m;
    const rect = inner.match(/<rect\b[^>]*>/);
    if (!rect) continue;
    const attr = (name) => {
      const hit = rect[0].match(new RegExp(`\\b${name}="([-\\d.]+)"`));
      return hit ? +hit[1] : null;
    };
    const x = attr("x"), y = attr("y"), w = attr("width"), h = attr("height");
    if ([x, y, w, h].some((v) => v === null)) continue;
    boxes[id] = {
      cx: x + w / 2,
      top: y,
      bottom: y + h,
      outward: cls.split(/\s+/).includes(OUTWARD_CLASS),
    };
  }
  return boxes;
}

/* ── replay the page's logic ─────────────────────────────────────────── */

function arrowPath(s, t) {
  const midY = Math.max(s.bottom + 6, Math.min(t.top - 30, t.top - 6));
  return Math.abs(s.cx - t.cx) < 2
    ? `M ${s.cx} ${s.bottom} L ${t.cx} ${t.top - 2}`
    : `M ${s.cx} ${s.bottom} L ${s.cx} ${midY} L ${t.cx} ${midY} L ${t.cx} ${t.top - 2}`;
}

function litNodes(view) {
  const lit = new Set();
  if (view.entry) lit.add(view.entry);
  for (const p of view.paths || []) p.forEach((id) => lit.add(id));
  for (const id of view.extras || []) lit.add(id);
  return lit;
}

function flowArrows(view, boxes) {
  const out = [];
  for (const path of view.paths || []) {
    for (let i = 0; i < path.length - 1; i++) {
      const s = boxes[path[i]], t = boxes[path[i + 1]];
      if (!s || !t) die(`view "${view.id}": no geometry for ${!s ? path[i] : path[i + 1]}`);
      const outward = t.outward;
      const cls = "bc-arrow bc-flow-arrow" + (outward ? " bc-flow-out" : "");
      const marker = outward ? "bc-flow-marker-out" : "bc-flow-marker";
      out.push(
        `<g class="${cls}"><path d="${arrowPath(s, t)}" marker-end="url(#${marker})"/></g>`
      );
    }
  }
  return out.join("\n    ");
}

const stripTags = (s) => s.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/* ── build one frame ─────────────────────────────────────────────────── */

function frame(view, { svg, css }, boxes, vars) {
  const lit = litNodes(view);
  const isOverview = view.id === "overview";

  // Bake highlight/dim onto the elements themselves. `all` covers the nodes and
  // entry zones; static arrows dim with everything else.
  let out = svg.replace(
    /<g class="([^"]*)" data-id="([^"]+)">/g,
    (whole, cls, id) => {
      if (lit.has(id)) return `<g class="${cls} bc-hl" data-id="${id}">`;
      if (isOverview) return whole;
      return `<g class="${cls} bc-dim" data-id="${id}">`;
    }
  );

  out = out.replace(/data-view="[^"]*"/, `data-view="${view.id}"`);
  out = out.replace(
    /<title id="bc-svg-title">[\s\S]*?<\/title>/,
    `<title id="bc-svg-title">${esc(view.title)}</title>`
  );
  out = out.replace(
    /<desc id="bc-svg-desc">[\s\S]*?<\/desc>/,
    `<desc id="bc-svg-desc">${esc(stripTags(view.body))}</desc>`
  );
  // A view with no paths leaves the container empty. Emitting the newlines
  // anyway would leave a whitespace-only line, which the trailing-whitespace
  // hook strips — so every re-export would dirty the tree and the generator and
  // the hook would take turns undoing each other.
  const arrows = flowArrows(view, boxes);
  out = out.replace(
    /<g class="bc-flow-arrows"><\/g>/,
    arrows ? `<g class="bc-flow-arrows">\n    ${arrows}\n  </g>` : `<g class="bc-flow-arrows"></g>`
  );

  const vb = out.match(/viewBox="([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)"/);
  if (!vb) die(`view "${view.id}": no viewBox on the root <svg>`);
  const [, , , width, height] = vb;

  // Explicit rules for the baked classes, plus a static background — a frame has
  // no page behind it. Animation goes: a still frame of a marching-ants dash is
  // just a dash.
  const extra = `
  /* ── added by export-frames.mjs ── */
  .bc-dim rect, .bc-dim text { opacity: ${vars["--bc-dim"] || "0.22"}; }
  .bc-dim .bc-entry-frame, .bc-dim .bc-entry-header { opacity: 0.38; }
  .bc-dim text.bc-entry-title { opacity: 0.6; }
  .bc-dim path { opacity: 0.18; }
  .bc-flow-arrow path { animation: none; }
`;

  const style = flatten(css, vars) + extra;

  out = out.replace(/^<svg class="bc-svg"([^>]*)>/, (whole, attrs) => {
    // The substrate's <svg> already carries xmlns; adding a second is a
    // duplicate-attribute parse error, not a harmless repeat.
    const ns = /\bxmlns=/.test(attrs) ? "" : ' xmlns="http://www.w3.org/2000/svg"';
    return (
      `<svg class="bc-svg"${ns} width="${width}" height="${height}"${attrs}>\n` +
      // CDATA, not a bare <style>: an SVG is XML, so a `<` anywhere in the
      // stylesheet — a `<svg>` inside a CSS comment, say — opens a tag and the
      // document stops parsing. Wrapping is unconditional so no future edit to
      // the substrate's CSS can reintroduce it.
      `  <style><![CDATA[${style}]]></style>\n` +
      `  <rect width="${width}" height="${height}" fill="${vars["--bc-surface"] || "#F7F8F5"}"/>`
    );
  });

  return out + "\n";
}

/* ── main ────────────────────────────────────────────────────────────── */

const file = process.argv[2] || "substrate-stack.html";
const path = join(DIAGRAMS, basename(file));
const html = readFileSync(path, "utf8");

const parsed = parse(html, basename(file));
const vars = tokens(parsed.css);
const boxes = geometry(parsed.svg);
const stem = basename(file).replace(/\.html$/, "");

const written = [];
for (const view of parsed.views) {
  const name = `${stem}-${view.id}.svg`;
  writeFileSync(join(DIAGRAMS, name), frame(view, parsed, boxes, vars), "utf8");
  written.push(name);
  console.log(`  ${name}`);
}

console.log(
  `\n${written.length} frame(s) from ${basename(file)}.` +
    `\nThese are generated — edit the substrate, never the frame.` +
    `\nList them in the substrate's \`generates\` array in manifest.json, then run tools/render-png.sh.`
);

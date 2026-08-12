# docs/diagrams/tools/

Three scripts, no dependencies beyond python3, bash and nix. The catalogue and the reasoning are in `../README.md`; this file covers only what is not obvious from reading the code.

| Script | Does |
|---|---|
| `check-manifest.py` | Validates `../manifest.json` against the tree; `--update` re-stamps source hashes, `--stamp` writes provenance blocks into the SVGs |
| `render-png.sh` | Every SVG to a 2× PNG beside it |
| `export-frames.mjs` | Static SVG frames out of an interactive substrate |

## Rules that are not obvious

- **The manifest is the single source of truth for provenance; the block inside each SVG is generated from it.** `--stamp` writes it, and the check fails if a block drifts from its manifest entry. Editing a provenance block by hand is not a way to change it — the next check rejects it. Change the manifest and re-stamp. This exists because a figure and its provenance living in two hand-maintained places is exactly the drift the whole mechanism is meant to catch.
- **A deleted source FAILS, a changed source WARNS**, and the asymmetry is deliberate — it is ADR-012's split. A figure whose subject was deleted describes nothing. A figure whose subject was *edited* is usually still true, so the warning is a prompt to look, not a verdict. Do not "fix" a warning by re-stamping without reading the diff; that converts the one signal here into noise.
- **`--` is illegal inside an XML comment**, so the generator turns any that survive in prose into en dashes. It sanitises the *body* only — sanitising the whole string would eat the comment delimiters. There is a test for this in the sense that any figure would fail XML parsing immediately; if you change the renderer, parse all five before believing it.
- **PNGs are not reproducible across machines and that is fine.** Text is plain `<text>` with no font embedding, so a renderer substitutes a local sans. Nothing depends on a particular face. A PNG diff is not a signal — never chase one.
- **`render-png.sh` re-execs itself inside `nix shell` when librsvg is missing**, using the resolved script path rather than `$0`, because it has already `cd`'d by that point.
- **Exported frames are generated artefacts.** They are listed in a substrate's `generates` array, inherit its provenance, and are exempt from the every-figure-is-in-the-manifest check. Edit the substrate, never the frame.

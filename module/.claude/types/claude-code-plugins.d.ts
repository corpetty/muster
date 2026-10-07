// Written by Claude Code 2.1.286.
// Claude Code function hooks: the enabled plugins' type contracts.
//
// Written by `/plugin-types` beside claude-code.d.ts; regenerate with that
// command rather than editing. Each enabled plugin that names a type
// contract in its manifest (`types`) has it copied verbatim, under a
// banner naming the plugin, its version and its tier, to claude-code-plugins/
// <plugin>.d.ts beside this file, which references each one below. A
// contract exports the types of the noun its plugin adds to `$` in
// engine.create and declares it on EngineInterface, so a plugin that
// depends on it is typed here with nothing copied: include this folder
// in the tsconfig, as the header of the file beside this one shows. A
// plugin whose contract could not be read, or did not check, is listed
// at the end with the reason.

// No enabled plugin names a type contract in its manifest.

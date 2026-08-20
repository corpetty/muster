#pragma once

#include "rep_muster_ui_source.h"
#include "logos_ui_plugin_context.h"

/**
 * @brief The muster-ui backend (universal authoring model).
 *
 * You write only this class + the `.rep` view contract; the `*Plugin` /
 * `*Interface` glue (Q_PLUGIN_METADATA, initLogos wiring, QtRO registration)
 * is generated around it.
 *
 * Derives:
 *   - `MusterUiSimpleSource` — generated from muster_ui.rep; implement its
 *     SLOTs and feed its PROPs (`setHealth(...)`), which auto-sync to QML.
 *   - `LogosUiPluginContext` — supplies `onContextReady()` + `modules()`, the
 *     Qt-typed callers for the declared `dependencies` (here: muster_module).
 */
class MusterUiBackend : public MusterUiSimpleSource,
                        public LogosUiPluginContext
{
public:
    void checkHealth() override;
    void onContextReady() override;
};

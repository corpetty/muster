#include "muster_ui_backend.h"

// Generated umbrella: LogosModules (behind modules()) built from
// metadata.json#dependencies — the typed muster_module client the UI calls
// through the logos API (no hand-written invokeRemoteMethod, no keys, no net).
#include "logos_sdk.h"

// The one seam the P4 loading spike proves: a QML view -> this C++ backend ->
// the generated muster_module client -> the Nim core, all through the logos
// API. `health()` returns the module's typed QString ("ok"); it lands in the
// .rep PROP, which QtRO pushes to the QML replica.
void MusterUiBackend::checkHealth()
{
    setHealth(modules().muster_module.health());
}

void MusterUiBackend::onContextReady()
{
    // Fires once ui-host hands the plugin its wired modules(); check liveness
    // immediately so the view shows the real health without a first click.
    checkHealth();
}

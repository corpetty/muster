## derived-exo-8dc s6/c6: no automatic update fetch — updates are manual, or come
## from an explicitly enabled (default-off) signed feed. Stepper over (feed
## enabled × feed signed × auto-trigger): a fetch happens only when the feed is
## explicitly enabled AND signed; never automatically or without consent. Emits
## {"config": "...", "unconsented_update_fetch": ...} (must be false).
import ../../src/transport/infra

var anyUnconsented = false
var states = 0
for enabled in [false, true]:
  for signed in [false, true]:
    for autoTrigger in [false, true]:
      if states >= 30: break
      var cfg = newConfig(@["feed"])
      cfg.updateFeedEnabled = enabled
      let fetched = wouldFetchUpdate(cfg, signed)
      # A fetch without explicit enablement (consent) is unconsented. Default-off
      # means enabled=false must never fetch, regardless of auto-trigger/signed.
      let unconsented = fetched and (not enabled)
      if unconsented: anyUnconsented = true
      echo "{\"config\": \"en", enabled, "-sig", signed, "-auto", autoTrigger,
           "\", \"unconsented_update_fetch\": ", (if unconsented: "true" else: "false"), "}"
      inc states
doAssert not anyUnconsented, "an update was fetched without explicit consent"

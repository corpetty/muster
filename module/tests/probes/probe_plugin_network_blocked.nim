## derived-exo-51e s3/c3: plugin code cannot make a network call, directly or
## indirectly. Across contexts, an attempt to use the network is not permitted.
## Emits {"blocked": ...}.
import ../../src/plugins/plugin

var allBlocked = true
for trial in 0 .. 199:
  let blocked = not permitted(opNetwork)
  if not blocked: allBlocked = false
  echo "{\"blocked\": ", (if blocked: "true" else: "false"), "}"
doAssert allBlocked, "plugin code was able to make a network call"

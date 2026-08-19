## derived-exo-51e s2/c2: plugin code cannot read or otherwise access key material.
## Across contexts, an attempt to read a key is not permitted. Emits {"blocked": ...}.
import ../../src/plugins/plugin

var allBlocked = true
for trial in 0 .. 199:
  let blocked = not permitted(opReadKey)
  if not blocked: allBlocked = false
  echo "{\"blocked\": ", (if blocked: "true" else: "false"), "}"
doAssert allBlocked, "plugin code was able to access key material"

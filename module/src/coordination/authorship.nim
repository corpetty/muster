## Author-signed events (exo-f76). SKELETON — the red commit: every call passes
## through unchanged, so a forged author-bearing event still reaches the folds.

import ../log/log
import ../crypto/keystore
import ./session

const
  AuthorDomain* = "muster.event.author.v1"
  AuthorSigField* = "authorSig"

proc authorOf*(e: Event): tuple[authored: bool, author: string] = (false, "")

proc authorDigest*(room: string, e: Event): array[32, byte] = discard

proc signAuthored*(ks: Keystore, room: string, e: Event): Event = e

proc authorVerified*(room: string, e: Event): bool = true

proc authenticEvents*(events: seq[Event], room: string): seq[Event] = events

proc events*(s: CoordinationSession): seq[Event] = s.log.allEvents()

proc publishAuthored*(s: CoordinationSession, ks: Keystore, e: Event) = s.publish(e)

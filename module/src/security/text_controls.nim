## Text a peer chose, made safe to show (exo-3b3.18, audit P4-09 / P4-10).
##
## A peer names files they share and suggests the alias a contact link pre-fills. Two tricks
## make such a name read as something it is not:
##   - Unicode format controls: U+202E (right-to-left override) shows "invoice<U+202E>fdp.exe"
##     as "invoiceexe.pdf"; the zero-width and isolate marks hide characters or reorder them.
##     `stripFormatControls` drops the ones that do this.
##   - look-alike letters: a Cyrillic "А" (U+0410) next to Latin letters reads "Alice".
##     `mixesScripts` says when a name mixes Latin letters with Cyrillic or Greek ones, for the
##     UI to flag; it never changes the name.
##
## Pure (std/unicode): headless-testable.

import std/unicode

proc isFormatControl*(r: Rune): bool =
  ## The bidirectional and zero-width controls a displayed name must not carry: U+200B–U+200F
  ## (zero-width space, joiners, LRM, RLM), U+202A–U+202E (embeddings and overrides),
  ## U+2066–U+2069 (isolates), U+FEFF (zero-width no-break space) and U+061C (Arabic letter mark).
  let c = int(r)
  (c >= 0x200B and c <= 0x200F) or (c >= 0x202A and c <= 0x202E) or
    (c >= 0x2066 and c <= 0x2069) or c == 0xFEFF or c == 0x061C

proc stripFormatControls*(s: string): string =
  ## `s` without those controls. A string that is not valid UTF-8 is returned with its
  ## invalid bytes replaced by "?", so nothing undecodable reaches a display.
  if validateUtf8(s) != -1:
    for ch in s:
      result.add(if ord(ch) < 0x80: ch else: '?')
    return
  for r in s.runes:
    if not isFormatControl(r): result.add r

proc isLatinLetter(c: int): bool =
  (c >= ord('A') and c <= ord('Z')) or (c >= ord('a') and c <= ord('z')) or
    (c >= 0x00C0 and c <= 0x024F and c != 0x00D7 and c != 0x00F7) or   # Latin-1 / Extended-A/B
    (c >= 0x1E00 and c <= 0x1EFF)                                       # Latin Extended Additional

proc isCyrillicLetter(c: int): bool =
  (c >= 0x0400 and c <= 0x052F) or (c >= 0x1C80 and c <= 0x1C8F) or
    (c >= 0x2DE0 and c <= 0x2DFF) or (c >= 0xA640 and c <= 0xA69F)

proc isGreekLetter(c: int): bool =
  (c >= 0x0370 and c <= 0x03FF) or (c >= 0x1F00 and c <= 0x1FFF)

proc mixesScripts*(s: string): bool =
  ## Does `s` mix Latin letters with Cyrillic or Greek ones (the look-alike scripts)? A name
  ## in one script, with digits, spaces and punctuation, does not.
  if validateUtf8(s) != -1: return false
  var latin, lookalike = false
  for r in s.runes:
    let c = int(r)
    if isLatinLetter(c): latin = true
    elif isCyrillicLetter(c) or isGreekLetter(c): lookalike = true
  latin and lookalike

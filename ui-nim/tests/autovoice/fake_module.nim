## A fake muster_module for the autovoice harness (gen.py includes it): the voice_* state
## machine of docs/design/voice-notes.md §8 as far as the autopilot sees it, a room of two
## members, and a thread holding the rows HARNESS_ROWS names, plus the note a Send made.
## HARNESS_REFUSE names a note whose Play is always refused (unknown-note). A note plays for
## three voice_status reads, then nothing plays. Start is answered at once and the recording
## is `starting` for 1.5 s, as the module starts the device on a thread of its own (§9); Stop
## while starting is not-started. The answers keep the module's shapes (voice_live.nim); no
## audio is anywhere, as none crosses the real IPC.
var
  queued: seq[proc () {.closure.}]
  calls: seq[string]          ## every voice_* call but voice_status, in order
  callAt: seq[float]          ## when each was made
  recState = "idle"
  startAt = 0.0               ## when voice_record_start was answered
  recordingAt = 0.0           ## when a voice_status first said recording
  playing = ""                ## the note playing, "" when none
  playReads = 0               ## voice_status reads since Play: the third ends it
  sentRows: seq[JsonNode]

proc status(): string =
  $(%*{"ready": {"capture": "ok", "playback": "ok", "codec": "libopus 1.5.2", "note": ""},
       "recording": {"state": recState, "elapsedMs": 0, "capMs": 60000, "peak": 0,
                     "capped": false, "silent": false, "error": ""},
       "playing": (if playing.len > 0: %*{"note": playing, "positionMs": 0, "durationMs": 3000,
                                            "starting": false}
                   else: newJNull())})

proc fake(name: string, a: seq[string]): string =
  if name.startsWith("voice_") and name != "voice_status":
    calls.add name & "(" & a.join(",") & ")"
    callAt.add epochTime()
  case name
  of "health": "ok"
  of "coordinate_join": $(%*{"topic": a[0]})
  of "coordinate_members":
    $(%*[{"identity": "aa", "self": true}, {"identity": "bb", "self": false}])
  of "coordinate_messages":
    var rows = parseJson(getEnv("HARNESS_ROWS", "[]"))
    for r in sentRows: rows.add r
    $rows
  of "voice_status":
    if recState == "starting" and epochTime() - startAt >= 1.5:
      recState = "recording"
      recordingAt = epochTime()
    if playing.len > 0:
      inc playReads
      if playReads >= 3: playing = ""
    status()
  of "voice_record_start":
    if recState != "idle": return $(%*{"error": "busy"})
    recState = "starting"
    startAt = epochTime()
    $(%*{"ok": true})
  of "voice_record_stop":
    if recState == "starting":
      recState = "idle"
      return $(%*{"error": "not-started"})
    if recState != "recording": return $(%*{"error": "not-recording"})
    recState = "draft"
    $(%*{"draft": {"durationMs": 1000, "silent": false, "peak": 16383}})
  of "voice_draft_send":
    if recState != "draft": return $(%*{"error": "no-draft"})
    recState = "idle"
    sentRows.add %*{"id": "e1", "author": "aa", "ts": 2, "body": "", "self": true, "alias": "",
                    "voice": {"v": 1, "note": "n1", "durationMs": 1000, "state": "complete"}}
    $(%*{"note": "n1"})
  of "voice_play":
    if a[0] == getEnv("HARNESS_REFUSE", "-"): return $(%*{"error": "unknown-note"})
    if playing.len > 0 or recState in ["starting", "recording"]: return $(%*{"error": "busy"})
    playing = a[0]
    playReads = 0
    $(%*{"ok": true})
  of "voice_play_stop": (playing = ""; "ok")
  of "voice_draft_discard": (recState = "idle"; "ok")
  else: ""

proc report() =
  echo "HARNESS-CALLS ", $(%calls)
  var gaps = newJArray()
  for i in 1 ..< callAt.len: gaps.add %int((callAt[i] - callAt[i - 1]) * 1000)
  echo "HARNESS-GAPS-MS ", $gaps
  echo "HARNESS-RECORDING-AFTER-MS ", (if recordingAt > 0: int((recordingAt - startAt) * 1000) else: -1)

## What an intent's effect does, in plain words (exo-59c). Stub — see the green commit.
type
  EffectSummary* = object
    kind*, amount*, unit*, to*, text*: string

proc effectSummary*(effectJson: string): EffectSummary = EffectSummary()

## libopus binding — the codec under voice notes (docs/design/voice-notes.md §3.1). We bind the
## reference implementation rather than carry a codec: libopus 1.5.2 from the builder's
## nixpkgs (BSD-3), linked the way libsodium is (metadata.json codegen.nim.link +
## nix.packages.runtime). Symbols resolve at link; the API is ABI-stable, so no header is
## needed, in the style of crypto/sodium.nim. Only voice_codec.nim calls these.
##
## The ctl functions are C variadics (`int opus_encoder_ctl(OpusEncoder *st, int request,
## ...)`, opus.h:328, :522) and MUST stay `{.varargs.}`. Apple arm64 passes variadic
## arguments on the stack and fixed ones in registers, so a fixed-arity declaration hands
## libopus's va_arg whatever is on the stack, and what happens depends on what is there. In
## the prototype (design §3.1) SET_BITRATE(16000) returned OPUS_OK and read back 300000 (a
## large value, clamped for mono); in this build on darwin-arm64 a fixed-arity SET failed
## with OPUS_BAD_ARG instead. AAPCS64 Linux and SysV x86_64 pass both alike, which is why
## only a Mac shows it. Every SET value is a `cint` (opus_int32), never a Nim `int` (64-bit),
## and every GET argument a `ptr cint`. Either failure is caught: a SET's return code is
## checked, and newClipEncoder and voice_codec_test §1 read every setting back.
##
## The request numbers below are libopus's own (opus_defines.h, the same in 1.5.2 and
## 1.6.1); re-check them against the -dev headers when the pin moves.

type
  OpusEncoder* = object          ## opaque: created, used and destroyed only by libopus
  OpusDecoder* = object

const
  OPUS_OK* = 0.cint
  OPUS_BAD_ARG* = -1.cint
  OPUS_INVALID_PACKET* = -4.cint
  OPUS_APPLICATION_VOIP* = 2048.cint
  OPUS_SIGNAL_VOICE* = 3001.cint
  OPUS_BANDWIDTH_WIDEBAND* = 1103.cint
  OPUS_SET_BITRATE_REQUEST* = 4002.cint
  OPUS_GET_BITRATE_REQUEST* = 4003.cint
  OPUS_SET_MAX_BANDWIDTH_REQUEST* = 4004.cint
  OPUS_GET_MAX_BANDWIDTH_REQUEST* = 4005.cint
  OPUS_SET_VBR_REQUEST* = 4006.cint
  OPUS_GET_VBR_REQUEST* = 4007.cint
  OPUS_SET_COMPLEXITY_REQUEST* = 4010.cint
  OPUS_GET_COMPLEXITY_REQUEST* = 4011.cint
  OPUS_SET_INBAND_FEC_REQUEST* = 4012.cint
  OPUS_GET_INBAND_FEC_REQUEST* = 4013.cint
  OPUS_SET_DTX_REQUEST* = 4016.cint
  OPUS_GET_DTX_REQUEST* = 4017.cint
  OPUS_SET_SIGNAL_REQUEST* = 4024.cint
  OPUS_GET_SIGNAL_REQUEST* = 4025.cint
  OPUS_GET_LOOKAHEAD_REQUEST* = 4027.cint

{.push importc, cdecl.}
proc opus_encoder_create*(fs: int32, channels: cint, application: cint, error: ptr cint): ptr OpusEncoder
proc opus_encoder_destroy*(st: ptr OpusEncoder)
proc opus_encode*(st: ptr OpusEncoder, pcm: ptr int16, frameSize: cint, data: ptr byte,
                  maxDataBytes: int32): int32
proc opus_encoder_ctl*(st: ptr OpusEncoder, request: cint): cint {.varargs.}
proc opus_decoder_create*(fs: int32, channels: cint, error: ptr cint): ptr OpusDecoder
proc opus_decoder_destroy*(st: ptr OpusDecoder)
proc opus_decode*(st: ptr OpusDecoder, data: ptr byte, len: int32, pcm: ptr int16,
                  frameSize: cint, decodeFec: cint): cint
proc opus_decoder_ctl*(st: ptr OpusDecoder, request: cint): cint {.varargs.}
proc opus_packet_get_nb_samples*(packet: ptr byte, len: int32, fs: int32): cint
proc opus_packet_pad*(data: ptr byte, len: int32, newLen: int32): cint
proc opus_get_version_string*(): cstring
proc opus_strerror*(error: cint): cstring
{.pop.}

## STUB (red phase): the API of the Monero address parser, every call refusing.
import std/options

type
  MoneroNetwork* = enum
    xmrMainnet = "mainnet", xmrTestnet = "testnet", xmrStagenet = "stagenet"
  MoneroAddressKind* = enum
    makStandard = "standard", makSubaddress = "subaddress", makIntegrated = "integrated"
  MoneroRefusal* = enum
    mrNone = "", mrBadBase58 = "bad-base58", mrBadLength = "bad-length",
    mrUnknownTag = "unknown-tag", mrBadChecksum = "bad-checksum", mrBadKey = "bad-key",
    mrUnknownChain = "unknown-chain", mrWrongNetwork = "wrong-network",
    mrIntegrated = "integrated-address", mrBadAmount = "bad-amount", mrBadUri = "bad-uri"
  MoneroAddress* = object
    ok*: bool
    refusal*: MoneroRefusal
    reason*: string
    network*: MoneroNetwork
    kind*: MoneroAddressKind
    spendKey*, viewKey*: array[32, byte]
    paymentId*: Option[array[8, byte]]
  DecodedAddr* = object
    refusal*: MoneroRefusal
    tag*: uint64
    data*: seq[byte]
  PaymentUri* = object
    ok*: bool
    refusal*: MoneroRefusal
    reason*, uri*: string
  ParsedUri* = object
    ok*: bool
    refusal*: MoneroRefusal
    reason*, address*, paymentId*, description*, recipientName*: string
    amount*: uint64
    unknown*: seq[string]

proc base58Encode*(data: openArray[byte]): string = ""
proc base58Decode*(s: string): Option[seq[byte]] = none(seq[byte])
proc encodeAddr*(tag: uint64, data: openArray[byte]): string = ""
proc decodeAddr*(s: string): DecodedAddr = DecodedAddr(refusal: mrBadBase58)
proc tagOf*(n: MoneroNetwork, k: MoneroAddressKind): uint64 = 0
proc decompresses*(key: array[32, byte]): bool = false
proc isValidKey*(key: array[32, byte]): bool = false
proc parseAddress*(s: string): MoneroAddress = MoneroAddress(refusal: mrBadBase58)
proc encodeAddress*(n: MoneroNetwork, k: MoneroAddressKind, spendKey, viewKey: array[32, byte],
                    paymentId = none(array[8, byte])): string = ""
proc standardOf*(a: MoneroAddress): string = ""
proc caip2Of*(n: MoneroNetwork): string = ""
proc networkOfChain*(chain: string): Option[MoneroNetwork] = none(MoneroNetwork)
proc acceptablePayTo*(address, chain: string): MoneroAddress = MoneroAddress(refusal: mrBadBase58)
proc formatXmr*(atomic: uint64): string = ""
proc parseXmr*(s: string): Option[uint64] = none(uint64)
proc urlEncode*(s: string): string = ""
proc urlDecode*(s: string): string = ""
proc makePaymentUri*(chain, address: string, amount: uint64, description = "",
                     recipientName = ""): PaymentUri = PaymentUri(refusal: mrBadUri)
proc makePaymentUri*(chain, address: string, amount: string, description = "",
                     recipientName = ""): PaymentUri = PaymentUri(refusal: mrBadUri)
proc parsePaymentUri*(uri, chain: string): ParsedUri = ParsedUri(refusal: mrBadUri)

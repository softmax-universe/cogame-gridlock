## Join, auth, slots and tokens. Forked in shape from paintbot's
## `src/ctf/roster.nim`, minus the reward/account machinery gridlock has no
## use for.
##
## Every seat must connect and register explicitly before gameplay starts.
## Malformed registration is rejected before any frozen policy fields change.

import std/[json, strutils]
import types
import baselines

type
  PolicyKind* = enum
    pkUnregistered, pkScripted, pkPrompt, pkExternal

  SeatRegistration* = object
    kind*: PolicyKind
    scripted*: ScriptKind
    policyLabel*: string
    prompt*: string
    connected*: bool
    everConnected*: bool
    registered*: bool

  Roster* = object
    tokens*: seq[string]
    seats*: array[Seats, SeatRegistration]

proc initRoster*(tokens: seq[string]): Roster =
  result.tokens = tokens
  for seat in 0 ..< Seats:
    result.seats[seat] = SeatRegistration(
      kind: pkUnregistered, scripted: skNone, policyLabel: "",
      connected: false, everConnected: false, registered: false)

proc authorize*(roster: Roster, slot: int, token: string): bool =
  slot >= 0 and slot < Seats and slot < roster.tokens.len and
    roster.tokens[slot].len > 0 and roster.tokens[slot] == token

proc applyRegistration*(roster: var Roster, slot: int, payload: JsonNode) =
  ## Registration is a live protocol, separate from stored replay readers.
  doAssert slot >= 0 and slot < Seats
  if payload.kind != JObject:
    raise newException(GridlockError, "invalid registration envelope")
  for key in ["type", "kind", "scripted", "policy", "prompt"]:
    if not payload.hasKey(key):
      raise newException(GridlockError, "registration missing required " & key)
  if payload["type"].kind != JString or payload["type"].getStr() != "register":
    raise newException(GridlockError, "invalid registration envelope")
  if payload["kind"].kind != JString or payload["policy"].kind != JString or
      payload["prompt"].kind != JString:
    raise newException(GridlockError, "registration kind, policy and prompt must be text")
  let kind =
    case payload["kind"].getStr()
    of "scripted": pkScripted
    of "prompt": pkPrompt
    of "external": pkExternal
    else: raise newException(GridlockError, "unknown player kind")
  let scriptedNode = payload["scripted"]
  let scripted =
    case scriptedNode.kind
    of JNull: skNone
    of JString: parseScriptKind(scriptedNode.getStr())
    else: raise newException(GridlockError, "scripted policy must be text or null")
  let resolvedScript =
    if kind == pkScripted:
      if scripted == skNone:
        raise newException(GridlockError,
          "scripted player must register an explicit scripted policy")
      scripted
    else:
      if scripted != skNone:
        raise newException(GridlockError,
          "external or prompt player cannot register a scripted plan")
      skNone
  var registration = roster.seats[slot]
  registration.kind = kind
  registration.scripted = resolvedScript
  registration.policyLabel = cleanLine(payload["policy"].getStr(), MaxPolicyRunes)
  if registration.policyLabel.len == 0:
    raise newException(GridlockError, "registered policy label must be nonempty")
  registration.prompt = clipRunes(payload["prompt"].getStr().strip(), 4000)
  registration.registered = true
  roster.seats[slot] = registration

proc policyKindOf*(seat: SeatRegistration): string =
  case seat.kind
  of pkScripted: "scripted"
  of pkPrompt, pkExternal: "llm"
  of pkUnregistered: "unregistered"

proc effectiveScript*(seat: SeatRegistration): ScriptKind =
  ## Explicit scripted policy for a registered scripted seat, or `skNone`.
  ## Unregistered or disconnected seats never acquire a fallback baseline.
  if seat.registered and seat.kind == pkScripted:
    seat.scripted
  else:
    skNone

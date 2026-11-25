## The routing plan: the schema a seat emits every turn, strict single-object
## JSON parsing, field validation, and the router coefficients derived from it.
##
## The RESOLVED plan is what is installed and what is recorded — playback never
## re-runs validation.

import std/[json, strutils, unicode]
import types

const
  DefaultCongestionWeight* = 40
  DefaultPatience* = 50
  DefaultDispatch* = 100
  DefaultSpread* = 40

  PlanKeys = [
    "congestion_weight", "patience", "dispatch", "spread",
    "corridor", "avoid", "priority", "note", "say"]

proc defaultPlan*(): RoutingPlan =
  RoutingPlan(
    congestionWeight: DefaultCongestionWeight,
    patience: DefaultPatience,
    dispatch: DefaultDispatch,
    spread: DefaultSpread,
    corridor: -1,
    avoid: -1,
    priority: prFifo,
    note: "",
    say: "",
    source: psScripted,
    latencyMs: 0)

proc replyHead(text: string): string =
  ## The head of a raw model reply goes into the exception message, which
  ## becomes `fallback.detail` in the replay: cut it on RUNE boundaries,
  ## never bytes. `cleanLine` also flattens the newlines.
  let head = cleanLine(text, MaxErrorHeadRunes)
  if head.runeLen >= MaxErrorHeadRunes: head & "..." else: head

# ---------------------------------------------------------------------------
# Strict single-object extraction: bare JSON object or inside a single
# ordinary outer Markdown code fence (JSON-tagged or plain). Surrounding prose,
# extra objects, or extra fenced blocks are rejected.
# ---------------------------------------------------------------------------

proc unwrapSingleFence(trimmed: string): string =
  if not trimmed.startsWith("```"):
    return trimmed
  let nl = trimmed.find('\n')
  if nl < 0:
    raise newException(GridlockError, "unclosed markdown code fence in reply")
  let tag = strutils.strip(trimmed[3 ..< nl], leading = false, trailing = true,
    chars = {' ', '\t', '\r'})
  if tag.len > 0 and tag.toLowerAscii() != "json":
    raise newException(GridlockError,
      "unsupported markdown code fence tag in reply: " & cleanLine(tag, 24))
  let rest = trimmed[nl + 1 .. ^1]
  if not rest.endsWith("```"):
    raise newException(GridlockError, "unclosed markdown code fence in reply")
  let closePos = rest.len - 3
  let prevNl = rest.rfind('\n', last = max(0, closePos - 1))
  let lineStart = if prevNl < 0: 0 else: prevNl + 1
  for i in lineStart ..< closePos:
    if rest[i] notin {' ', '\t'}:
      raise newException(GridlockError, "closing markdown fence must sit on its own line")
  let bodyEnd =
    if prevNl < 0: 0
    elif prevNl > 0 and rest[prevNl - 1] == '\r': prevNl - 1
    else: prevNl
  strutils.strip(rest[0 ..< bodyEnd])

proc extractJsonObject*(text: string): JsonNode =
  let trimmed = strutils.strip(text)
  if trimmed.len == 0:
    raise newException(GridlockError, "empty reply")
  let body = unwrapSingleFence(trimmed)
  if not body.startsWith("{") or not body.endsWith("}"):
    raise newException(GridlockError,
      "reply must be a single JSON object: " & replyHead(text))
  try:
    result = parseJson(body)
  except CatchableError as error:
    raise newException(GridlockError,
      "invalid JSON object in reply (" & cleanLine(error.msg, 80) & "): " &
      replyHead(text))
  if result.kind != JObject:
    raise newException(GridlockError,
      "reply must be a single JSON object: " & replyHead(text))

proc pctField(node: JsonNode, key: string, fallback: int): int =
  if not node.hasKey(key):
    return fallback
  let field = node[key]
  if field.kind != JInt:
    raise newException(GridlockError, key & " must be an integer in 0..100")
  let value = int(field.getInt())
  if value < 0 or value > 100:
    raise newException(GridlockError, key & " out of range 0..100: " & $value)
  value

proc districtField(node: JsonNode, key: string, fallback: int): int =
  if not node.hasKey(key):
    return fallback
  let field = node[key]
  case field.kind
  of JNull:
    -1
  of JArray:
    if field.len != 2 or field[0].kind != JInt or field[1].kind != JInt:
      raise newException(GridlockError,
        key & " must be [bx, by] with integer coordinates in 0..2 or null")
    let bx = int(field[0].getInt())
    let by = int(field[1].getInt())
    if bx < 0 or bx >= DistrictCols or by < 0 or by >= DistrictRows:
      raise newException(GridlockError,
        key & " coordinates out of range 0..2: [" & $bx & "," & $by & "]")
    districtIndex(bx, by)
  else:
    raise newException(GridlockError,
      key & " must be [bx, by] with integer coordinates in 0..2 or null")

proc parsePriority*(text: string): Priority =
  case text
  of "near": prNear
  of "far": prFar
  of "fifo": prFifo
  else:
    raise newException(GridlockError,
      "priority must be \"near\", \"far\", or \"fifo\"")

proc hasAnyPlanKey*(node: JsonNode): bool =
  if node == nil or node.kind != JObject:
    return false
  for key in PlanKeys:
    if node.hasKey(key):
      return true
  false

proc parsePlanObject*(node: JsonNode, previous: RoutingPlan): RoutingPlan =
  ## Validates a routing plan JSON object against `previous` (the plan the seat
  ## played last turn, or `defaultPlan()` on turn 0). Omitted optional fields
  ## keep their documented defaults; invalid types, unknown keys, legacy
  ## formats, out-of-range values, and conflicting corridor/avoid are rejected.
  if node == nil or node.kind != JObject:
    raise newException(GridlockError, "routing plan must be a JSON object")
  if node.len == 0:
    raise newException(GridlockError, "reply carried no plan keys")
  for key in node.keys:
    if key notin PlanKeys:
      raise newException(GridlockError,
        "unknown plan key: " & cleanLine(key, 32))
  result = previous
  result.source = psLlm
  result.latencyMs = 0
  result.note = ""
  result.say = ""
  result.congestionWeight =
    pctField(node, "congestion_weight", previous.congestionWeight)
  result.patience = pctField(node, "patience", previous.patience)
  result.dispatch = pctField(node, "dispatch", previous.dispatch)
  result.spread = pctField(node, "spread", previous.spread)
  result.corridor = districtField(node, "corridor", previous.corridor)
  result.avoid = districtField(node, "avoid", previous.avoid)
  if result.avoid >= 0 and result.avoid == result.corridor:
    raise newException(GridlockError,
      "corridor and avoid cannot name the same district")
  if node.hasKey("priority"):
    let priorityNode = node["priority"]
    if priorityNode.kind != JString:
      raise newException(GridlockError,
        "priority must be \"near\", \"far\", or \"fifo\"")
    result.priority = parsePriority(priorityNode.getStr())
  else:
    result.priority = prFifo
  if node.hasKey("note"):
    let noteNode = node["note"]
    if noteNode.kind != JString:
      raise newException(GridlockError, "note must be a string")
    result.note = cleanLine(noteNode.getStr(), MaxNoteRunes)
  if node.hasKey("say"):
    let sayNode = node["say"]
    if sayNode.kind != JString:
      raise newException(GridlockError, "say must be a string")
    result.say = cleanLine(sayNode.getStr(), MaxSayRunes)

proc parsePlan*(text: string, previous: RoutingPlan): RoutingPlan =
  ## Strict parse + validation of a model reply text.
  let node = extractJsonObject(text)
  parsePlanObject(node, previous)

proc planJson*(plan: RoutingPlan): JsonNode =
  result = %*{
    "congestion_weight": plan.congestionWeight,
    "patience": plan.patience,
    "dispatch": plan.dispatch,
    "spread": plan.spread,
    "priority": $plan.priority,
    "note": plan.note,
    "say": plan.say}
  result["corridor"] =
    if plan.corridor < 0: newJNull()
    else: %[districtX(plan.corridor), districtY(plan.corridor)]
  result["avoid"] =
    if plan.avoid < 0: newJNull()
    else: %[districtX(plan.avoid), districtY(plan.avoid)]

proc planFromJson*(node: JsonNode): RoutingPlan =
  ## Reads back a RECORDED plan (already resolved) from a replay or last_plan.
  if node == nil or node.kind != JObject:
    raise newException(GridlockError, "recorded plan must be a JSON object")
  var stripped = newJObject()
  for key in PlanKeys:
    if node.hasKey(key):
      stripped[key] = node[key]
  result = parsePlanObject(stripped, defaultPlan())
  result.source =
    case node{"source"}.getStr("scripted")
    of "llm": psLlm
    of "fallback": psFallback
    else: psScripted
  result.latencyMs = node{"latency_ms"}.getInt(0)

# ---------------------------------------------------------------------------
# Derived router coefficients.
# ---------------------------------------------------------------------------

proc replanQueue*(plan: RoutingPlan): int {.inline.} =
  ## Patience 0 -> re-plan when the next lane holds 3 vans; 100 -> 13.
  3 + (plan.patience * 10) div 100

proc activeCap*(plan: RoutingPlan, fleetSize: int): int {.inline.} =
  (plan.dispatch * fleetSize + fleetSize) div 100

proc releasePerStep*(plan: RoutingPlan): int {.inline.} =
  ## Spread 0 -> bursts of six; 100 -> one at a time.
  1 + ((100 - plan.spread) * 5) div 100

proc planIsLegal*(plan: RoutingPlan): bool =
  plan.congestionWeight in 0 .. 100 and plan.patience in 0 .. 100 and
    plan.dispatch in 0 .. 100 and plan.spread in 0 .. 100 and
    plan.corridor in -1 .. (DistrictCount - 1) and
    plan.avoid in -1 .. (DistrictCount - 1) and
    (plan.avoid < 0 or plan.avoid != plan.corridor) and
    plan.note.runeLen <= MaxNoteRunes and plan.say.runeLen <= MaxSayRunes

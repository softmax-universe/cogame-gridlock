## Game-owned decision exchange, strict plan validation, and turn timing.
## Model calls and candidate ranking live in ordinary player policies.

import std/[json, monotimes, options, times]
import bitworld/[decision_trajectory, native_stop]
import types, view, plan, baselines

const
  FirstAttemptSeconds = 14
  RetryAttemptSeconds = 6

type
  SeatSnapshot* = object
    view*: JsonNode
    prompt*: string
    baseline*: BaselineInput
    scripted*: ScriptKind
    previous*: RoutingPlan

  PlayerFallback* = object
    seat*: int
    attempt*: int
    cause*: FallbackCause
    detail*: string

  PlayerDecision* = object
    plans*: array[Seats, RoutingPlan]
    fallbacks*: seq[PlayerFallback]
    attempts*: array[Seats, seq[DecisionAttempt]]
    selectedAttemptIds*: array[Seats, Option[string]]
    failedSeats*: seq[int]
    failureDetail*: string

  DecisionExchange* = proc (requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.}

type
  ProposalKind* = enum pkAccepted, pkRejected
  PlayerProposal* = object
    kind*: ProposalKind
    plan*: RoutingPlan
    evidence*: DecisionAttempt
    cause*: FallbackCause
    detail*: string

proc playerProposal*(raw: string, requestId: string, seat: int,
    snapshot: SeatSnapshot): PlayerProposal =
  ## Shared player action parser boundary; installation remains engine-owned.
  result.evidence = newDecisionAttempt($seat & "-" & $requestId, "external", aoUnknown)
  result.evidence.response = %raw
  var timedOut = false
  var noCredentials = false
  try:
    let reply = parseJson(raw)
    if reply.hasKey("training_attempt") and reply["training_attempt"].kind != JNull:
      result.evidence = readAttemptEvidence(reply["training_attempt"])
      if result.evidence.origin in {aoTeacher, aoHuman}:
        result.evidence.origin = aoUnknown
    if reply["type"].getStr() == "attempt_timeout":
      timedOut = true
      raise newException(GridlockError, "player plan timed out after model request")
    if reply["type"].getStr() != "action" or
        reply["protocol"].getStr() != PlayerProtocol or
        reply["decision_id"].getStr() != requestId:
      raise newException(GridlockError, "player action envelope mismatch")
    if reply{"cause"}.getStr() == "no_credentials":
      noCredentials = true
      raise newException(GridlockError, "no native model endpoint configured")
    if reply{"source"}.getStr() != "llm":
      raise newException(GridlockError, "player action source must be llm")
    let proposed = reply["action"]
    if proposed.kind != JObject:
      if result.evidence.rejectionReason.isSome:
        raise newException(GridlockError, result.evidence.rejectionReason.get())
      raise newException(GridlockError, "player action must be a routing plan object")
    result.plan = parsePlanObject(proposed, snapshot.previous)
    result.plan.source = psLlm
    if result.evidence.origin == aoModel:
      if result.evidence.response.kind != JString:
        raise newException(GridlockError, "model attempt response must be text")
      if result.evidence.responseComplete != some(true) or
          result.evidence.responseReaderJoined != some(true) or
          result.evidence.httpStatus != some(200) or
          result.evidence.rawResponse.kind != JString or result.evidence.model.isNone or
          result.evidence.rejectionReason.isSome:
        raise newException(GridlockError, "model action requires its successful complete joined native response")
      let served = parseJson(result.evidence.rawResponse.getStr())
      if served.kind != JObject or served["content"].kind != JArray or
          served["model"] != %result.evidence.model.get():
        raise newException(GridlockError, "selected model differs from received native body")
      var text = ""
      for contentBlock in served["content"]:
        if contentBlock["type"].getStr() == "text": text.add(contentBlock["text"].getStr())
      if %text != result.evidence.response:
        raise newException(GridlockError, "selected response differs from received native body")
      let sampled = parsePlan(result.evidence.response.getStr(), snapshot.previous)
      result.evidence.parsedAction = planJson(sampled)
      if result.evidence.parsedAction != planJson(result.plan):
        raise newException(GridlockError, "model response differs from player action")
    else:
      result.evidence.parsedAction = planJson(result.plan)
    result.kind = pkAccepted
    result.evidence.accepted = true
  except CatchableError as error:
    result.kind = pkRejected
    result.cause =
      if noCredentials:
        fcNoCredentials
      elif timedOut:
        fcTimeout
      elif result.evidence.origin == aoModel and result.evidence.httpStatus.isSome and
          result.evidence.httpStatus.get() != 200:
        fcTransportError
      else:
        fcParseError
    result.detail = cleanLine(error.msg, MaxDetailRunes)
    if result.evidence.rejectionReason.isNone:
      result.evidence.rejectionReason = some(error.msg)

proc decidePlayers*(seats: array[Seats, SeatSnapshot], turn: int,
    guarded: bool, turnBudgetSeconds: float,
    exchange: DecisionExchange): PlayerDecision =
  ## Send all private views before either shared deadline starts. One invalid
  ## or missing reply gets a second attempt; a model seat that still fails
  ## surfaces in `failedSeats` rather than receiving a substituted baseline move.
  var pending: seq[int]
  var lastFailure: array[Seats, string]
  for seat in 0 ..< Seats:
    if seats[seat].scripted != skNone:
      result.plans[seat] = scriptedPlan(seats[seat].baseline, seats[seat].scripted)
    elif guarded:
      result.fallbacks.add(PlayerFallback(seat: seat, attempt: 0,
        cause: fcBudgetGuard, detail: "budget guard engaged"))
      lastFailure[seat] = "budget guard engaged"
      result.failedSeats.add(seat)
    else:
      pending.add(seat)

  let turnStart = getMonoTime()
  for attempt in 1 .. 2:
    if pending.len == 0 or interruptionRequested():
      break
    let remainingMs = int(turnBudgetSeconds * 1000.0) -
      (getMonoTime() - turnStart).inMilliseconds.int
    if remainingMs <= 0:
      break
    let timeoutMs = min(remainingMs,
      if attempt == 1: FirstAttemptSeconds * 1000
      else: RetryAttemptSeconds * 1000)
    var requests: seq[JsonNode]
    for seat in pending:
      requests.add(%*{
        "type": "decision",
        "protocol": PlayerProtocol,
        "decision_id": $turn & "-" & $seat & "-" & $attempt,
        "slot": seat,
        "turn": turn,
        "attempt": attempt,
        "transport": {"budget_ms": timeoutMs, "cleanup_budget_ms": 5000},
        "observation": seats[seat].view,
        "prompt": seats[seat].prompt
      })
    let started = getMonoTime()
    let replies = exchange(requests, timeoutMs)
    let latencyMs = max(0, (getMonoTime() - started).inMilliseconds.int)
    var retry: seq[int]
    for position, seat in pending:
      if position >= replies.len or replies[position].len == 0:
        var missing = newDecisionAttempt($seat & "-" & requests[position]["decision_id"].getStr(),
          "external", aoUnknown)
        missing.rejectionReason = some("player plan timed out")
        result.attempts[seat].add(missing)
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: fcTimeout, detail: "player plan timed out"))
        lastFailure[seat] = "player plan timed out"
        retry.add(seat)
        continue
      let proposal = playerProposal(replies[position],
        requests[position]["decision_id"].getStr(), seat, seats[seat])
      result.attempts[seat].add(proposal.evidence)
      case proposal.kind
      of pkAccepted:
        result.plans[seat] = proposal.plan
        result.plans[seat].latencyMs = latencyMs
        result.selectedAttemptIds[seat] = some(proposal.evidence.attemptId)
      of pkRejected:
        let detail =
          if proposal.detail.len > 0: proposal.detail
          else: "invalid private player reply"
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: proposal.cause, detail: detail))
        lastFailure[seat] = detail
        if proposal.cause == fcNoCredentials:
          result.failedSeats.add(seat)
        else:
          retry.add(seat)
    pending = retry

  for seat in pending:
    result.failedSeats.add(seat)
  if result.failedSeats.len > 0 and result.failureDetail.len == 0:
    let seat = result.failedSeats[0]
    let detail =
      if lastFailure[seat].len > 0: lastFailure[seat]
      else: "player failed to supply a valid routing plan"
    result.failureDetail = "seat " & $seat & " failed on turn " & $turn & ": " & detail

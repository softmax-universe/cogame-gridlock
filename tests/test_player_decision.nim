import std/[json, options, unittest]
import gridlock/[types, plan, baselines, view, decision]
import bitworld/decision_trajectory

var calls = 0

proc mixedReplies(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  inc calls
  if calls == 1:
    doAssert requests.len == 2
    doAssert requests[0]["observation"]["seat"].getInt() == 0
    doAssert requests[1]["observation"]["seat"].getInt() == 1
    doAssert requests[0]["decision_id"].getStr() != requests[1]["decision_id"].getStr()
    doAssert timeoutMs == 14000
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": requests[0]["decision_id"], "source": "llm",
      "action": {"dispatch": 70, "priority": "near"}})
    result.add("not json")
  else:
    doAssert requests.len == 1
    doAssert requests[0]["slot"].getInt() == 1
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": requests[0]["decision_id"], "source": "llm",
      "action": {"dispatch": 60, "priority": "far"}})

proc noCredentials(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  doAssert requests.len == 2
  for request in requests:
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": request["decision_id"], "source": "llm",
      "action": newJNull(), "cause": "no_credentials"})

proc snapshots(): array[Seats, SeatSnapshot] =
  for seat in 0 ..< Seats:
    result[seat] = SeatSnapshot(
      view: %*{"seat": seat},
      baseline: BaselineInput(),
      previous: defaultPlan(),
      scripted: (if seat < 2: skNone else: skDispatcher))

suite "ordinary player decision exchange":
  test "simultaneous private views, retry, and strict plan validation":
    calls = 0
    let decision = decidePlayers(snapshots(), 0, false, 22.0, mixedReplies)
    check calls == 2
    check decision.failedSeats.len == 0
    check decision.plans[0].source == psLlm
    check decision.plans[0].dispatch == 70
    check decision.plans[1].source == psLlm
    check decision.plans[1].dispatch == 60
    check decision.plans[1].priority == prFar
    check decision.plans[2].source == psScripted
    check decision.fallbacks.len == 1
    check decision.fallbacks[0].seat == 1
    check decision.fallbacks[0].cause == fcParseError
    check decision.attempts[0].len == 1
    check decision.attempts[1].len == 2
    check not decision.attempts[1][0].accepted
    check decision.attempts[1][1].accepted
    check decision.attempts[1][1].parsedAction == planJson(decision.plans[1])
    check decision.selectedAttemptIds[1].get() == decision.attempts[1][1].attemptId

  test "missing credentials fail unscored without substituting dispatcher":
    let decision = decidePlayers(snapshots(), 0, false, 22.0, noCredentials)
    check decision.failedSeats == @[0, 1]
    check decision.failureDetail.len > 0
    check decision.plans[0].source != psFallback
    check decision.plans[1].source != psFallback
    check decision.fallbacks.len == 2
    check decision.fallbacks[0].cause == fcNoCredentials
    check decision.selectedAttemptIds[0].isNone
    check decision.attempts[0].len == 1
    check not decision.attempts[0][0].accepted

  test "fallback source and string action shims are always rejected":
    let credFallback = $(%*{"type": "action", "protocol": PlayerProtocol,
      "decision_id": "1", "source": "fallback", "cause": "no_credentials"})
    let credProposal = playerProposal(credFallback, "1", 0, snapshots()[0])
    check credProposal.kind == pkRejected
    check credProposal.cause == fcNoCredentials
    let nonCredFallback = $(%*{"type": "action", "protocol": PlayerProtocol,
      "decision_id": "1", "source": "fallback", "cause": "transport_error"})
    check playerProposal(nonCredFallback, "1", 0, snapshots()[0]).kind == pkRejected
    let stringAction = $(%*{"type": "action", "protocol": PlayerProtocol,
      "decision_id": "1", "source": "llm", "action": "{\"dispatch\":70}"})
    check playerProposal(stringAction, "1", 0, snapshots()[0]).kind == pkRejected

  test "budget guard fails model seats instead of substituting dispatcher":
    proc unused(requests: seq[JsonNode], timeoutMs: int): seq[string] {.gcsafe.} =
      doAssert false, "exchange must not be called when guarded"
    let decision = decidePlayers(snapshots(), 0, true, 22.0, unused)
    check decision.failedSeats == @[0, 1]
    check decision.plans[0].source != psFallback
    check decision.plans[1].source != psFallback
    check decision.plans[2].source == psScripted
    check decision.fallbacks.len == 2
    check decision.fallbacks[0].cause == fcBudgetGuard

  test "external origins cannot mint server-owned teacher or human labels":
    for origin in [aoTeacher, aoHuman]:
      let asserted = newDecisionAttempt("asserted", "external-policy", origin)
      let raw = $(%*{"type": "action", "protocol": PlayerProtocol, "decision_id": "1",
        "source": "llm", "action": {"dispatch": 70},
        "training_attempt": asserted.attemptEvidenceJson()})
      let proposal = playerProposal(raw, "1", 0, snapshots()[0])
      check proposal.kind == pkAccepted
      check proposal.evidence.origin == aoUnknown
      check proposal.evidence.accepted
      check proposal.evidence.parsedAction == planJson(proposal.plan)

  test "a model reply cannot label a different executed player plan":
    var evidence = newDecisionAttempt("sampled", "model-policy", aoModel)
    evidence.response = %"{\"dispatch\":40}"
    evidence.model = some("fixture-model")
    evidence.rawResponse = %($(%*{"model": "fixture-model", "content": [
      {"type": "text", "text": evidence.response}]}))
    evidence.responseComplete = some(true)
    evidence.responseReaderJoined = some(true)
    evidence.httpStatus = some(200)
    let raw = $(%*{"type": "action", "protocol": PlayerProtocol, "decision_id": "1",
      "source": "llm", "action": {"dispatch": 70},
      "training_attempt": evidence.attemptEvidenceJson()})
    let proposal = playerProposal(raw, "1", 0, snapshots()[0])
    check proposal.kind == pkRejected
    check not proposal.evidence.accepted
    check proposal.evidence.parsedAction["dispatch"].getInt() == 40
    check proposal.plan.dispatch == 70

  test "fenced model response matches its submitted action object":
    var evidence = newDecisionAttempt("fenced", "model-policy", aoModel)
    evidence.response = %"```json\n{\"dispatch\":70}\n```"
    evidence.model = some("fixture-model")
    evidence.rawResponse = %($(%*{"model": "fixture-model", "content": [
      {"type": "text", "text": evidence.response}]}))
    evidence.responseComplete = some(true)
    evidence.responseReaderJoined = some(true)
    evidence.httpStatus = some(200)
    let raw = $(%*{"type": "action", "protocol": PlayerProtocol, "decision_id": "1",
      "source": "llm", "action": {"dispatch": 70},
      "training_attempt": evidence.attemptEvidenceJson()})
    let proposal = playerProposal(raw, "1", 0, snapshots()[0])
    check proposal.kind == pkAccepted
    check proposal.evidence.accepted
    check proposal.plan.dispatch == 70


suite "ordinary exchange retries":
  test "two invalid replies surface seat failure instead of substituting dispatcher":
    var exchanges = 0
    var seats = snapshots()
    for seat in 0 ..< Seats: seats[seat].scripted = skNone
    proc invalid(requests: seq[JsonNode], timeoutMs: int): seq[string] {.gcsafe.} =
      inc exchanges
      for request in requests: result.add("no idea")
    let decision = decidePlayers(seats, 0, false, 22.0, invalid)
    check exchanges == 2
    check decision.fallbacks.len == Seats * 2
    check decision.failedSeats == @[0, 1, 2, 3]
    check decision.failureDetail.len > 0
    for seat in 0 ..< Seats:
      check decision.plans[seat].source != psFallback
      check decision.attempts[seat].len == 2
      check decision.selectedAttemptIds[seat].isNone

  test "one missing first reply retries only once through the normal parser":
    var exchanges = 0
    var seats = snapshots()
    for seat in 0 ..< Seats: seats[seat].scripted = skNone
    proc retry(requests: seq[JsonNode], timeoutMs: int): seq[string] {.gcsafe.} =
      inc exchanges
      for request in requests:
        if exchanges == 1:
          result.add("")
        else:
          result.add($(%*{"type": "action", "protocol": PlayerProtocol,
            "decision_id": request["decision_id"], "source": "llm",
            "action": {"congestion_weight": 55, "patience": 75}}))
    let decision = decidePlayers(seats, 0, false, 22.0, retry)
    check exchanges == 2
    check decision.failedSeats.len == 0
    check decision.fallbacks.len == Seats
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psLlm
      check decision.plans[seat].congestionWeight == 55
      check decision.attempts[seat].len == 2
      check decision.attempts[seat][0].rejectionReason.get() == "player plan timed out"
      check decision.attempts[seat][1].accepted

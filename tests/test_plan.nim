## Strict single-object JSON parsing, field validation, rune-safe truncation,
## and the derived router coefficients.

import std/[json, unicode, unittest]
import support/helpers

suite "strict parsing":
  setup:
    let previous = defaultPlan()

  test "a clean bare JSON object parses":
    let plan = parsePlan(fakeReplyPlan(65, 80), previous)
    check plan.congestionWeight == 65
    check plan.dispatch == 80
    check plan.priority == prNear
    check plan.source == psLlm

  test "a single outer markdown code fence (json-tagged or plain) parses":
    let tagged = "```json\n" & fakeReplyPlan(12, 70) & "\n```"
    let planA = parsePlan(tagged, previous)
    check planA.congestionWeight == 12
    check planA.dispatch == 70
    let plain = "```\n" & fakeReplyPlan(24, 60) & "\n```"
    let planB = parsePlan(plain, previous)
    check planB.congestionWeight == 24
    check planB.dispatch == 60
    let upperTag = "```JSON\r\n" & fakeReplyPlan(36, 50) & "\r\n```"
    let planC = parsePlan(upperTag, previous)
    check planC.congestionWeight == 36

  test "surrounding prose and extra objects are rejected":
    expect GridlockError:
      discard parsePlan("Sure! Here is my plan:\n" & fakeReplyPlan(30, 90), previous)
    expect GridlockError:
      discard parsePlan(fakeReplyPlan(30, 90) & "\nLet me know if you want more.", previous)
    expect GridlockError:
      discard parsePlan("Here:\n```json\n" & fakeReplyPlan(30, 90) & "\n```", previous)
    expect GridlockError:
      discard parsePlan("```json\n" & fakeReplyPlan(30, 90) & "\n```\nDone.", previous)
    expect GridlockError:
      discard parsePlan("""{"dispatch":50} {"dispatch":80}""", previous)
    expect GridlockError:
      discard parsePlan("```json\n{\"dispatch\":50}\n```\n```json\n{\"dispatch\":80}\n```", previous)
    expect GridlockError:
      discard parsePlan("```python\n{\"dispatch\":50}\n```", previous)

  test "legacy numeric coercions and out-of-range integers are rejected":
    for bad in [
      """{"congestion_weight":"70%"}""",
      """{"patience":"25"}""",
      """{"dispatch":55.4}""",
      """{"spread":true}""",
      """{"dispatch":null}""",
      """{"congestion_weight":-1}""",
      """{"patience":101}""",
      """{"dispatch":300}""",
      """{"spread":-40}""",
    ]:
      expect GridlockError:
        discard parsePlan(bad, previous)

  test "legacy corridor/avoid formats, out-of-range districts, and wrong arity are rejected":
    for bad in [
      """{"congestion_weight":10,"corridor":{"bx":1,"by":1}}""",
      """{"congestion_weight":10,"corridor":"centre"}""",
      """{"congestion_weight":10,"corridor":"SE"}""",
      """{"congestion_weight":10,"corridor":"nowhere"}""",
      """{"dispatch":50,"corridor":[9,-4]}""",
      """{"dispatch":50,"corridor":[1]}""",
      """{"dispatch":50,"corridor":[1,1,1]}""",
      """{"dispatch":50,"avoid":["1","1"]}""",
    ]:
      expect GridlockError:
        discard parsePlan(bad, previous)

  test "valid corridor and avoid coordinates parse and explicit null clears previous":
    let first = parsePlan("""{"dispatch":80,"corridor":[0,1],"avoid":[1,1]}""", previous)
    check first.corridor == districtIndex(0, 1)
    check first.avoid == districtIndex(1, 1)
    let cleared = parsePlan("""{"corridor":null,"avoid":null}""", first)
    check cleared.corridor == -1
    check cleared.avoid == -1

  test "a plan may not prefer and shun the same district":
    expect GridlockError:
      discard parsePlan("""{"dispatch":80,"corridor":[1,1],"avoid":[1,1]}""", previous)

  test "invalid priorities and priority aliases are rejected; missing priority defaults to fifo":
    check parsePlan("""{"dispatch":80}""", previous).priority == prFifo
    check parsePlan("""{"dispatch":80,"priority":"near"}""", previous).priority == prNear
    check parsePlan("""{"dispatch":80,"priority":"far"}""", previous).priority == prFar
    check parsePlan("""{"dispatch":80,"priority":"fifo"}""", previous).priority == prFifo
    for bad in [
      """{"dispatch":80,"priority":"sideways"}""",
      """{"dispatch":80,"priority":"nearest"}""",
      """{"dispatch":80,"priority":"close"}""",
      """{"dispatch":80,"priority":"furthest"}""",
      """{"dispatch":80,"priority":"FaR"}""",
      """{"dispatch":80,"priority":1}""",
    ]:
      expect GridlockError:
        discard parsePlan(bad, previous)

  test "unknown keys and non-string note/say are rejected":
    expect GridlockError:
      discard parsePlan("""{"dispatch":80,"throttle":50}""", previous)
    expect GridlockError:
      discard parsePlan("""{"dispatch":80,"note":123}""", previous)
    expect GridlockError:
      discard parsePlan("""{"dispatch":80,"say":true}""", previous)

  test "omitted optional fields keep previous turn's plan and turn zero defaults":
    var earlier = defaultPlan()
    earlier.congestionWeight = 77
    earlier.patience = 12
    earlier.dispatch = 34
    earlier.spread = 56
    earlier.corridor = districtIndex(2, 0)
    let plan = parsePlan("""{"note":"held"}""", earlier)
    check plan.congestionWeight == 77
    check plan.patience == 12
    check plan.dispatch == 34
    check plan.spread == 56
    check plan.corridor == districtIndex(2, 0)
    check plan.note == "held"

    let first = parsePlan("""{"note":"first"}""", defaultPlan())
    check first.congestionWeight == 40
    check first.patience == 50
    check first.dispatch == 100
    check first.spread == 40

  test "a reply with no plan keys at all is rejected":
    expect GridlockError:
      discard parsePlan("""{}""", previous)
    expect GridlockError:
      discard parsePlan("""{"weather":"fine"}""", previous)
    expect GridlockError:
      discard parsePlan("I am not going to answer that.", previous)

  test "the quoted head of an unparseable reply is cut on a rune boundary":
    ## That message becomes `fallback.detail` in the replay, so it must not
    ## carry half a multi-byte character out of the model's reply. The truck
    ## emoji is 4 bytes, so a byte cut at 160 would split one.
    var prose = ""
    for _ in 0 ..< 300:
      prose.add("\xF0\x9F\x9A\x9A")
    var caught = ""
    try:
      discard parsePlan(prose, previous)
    except GridlockError as error:
      caught = error.msg
    check caught.len > 0
    check validateUtf8(caught) == -1
    check caught.runeLen <= MaxErrorHeadRunes + 60
    check cleanLine(caught, MaxDetailRunes).runeLen <= MaxDetailRunes
    check validateUtf8(cleanLine(caught, MaxDetailRunes)) == -1

suite "rune-safe truncation":
  test "a 400-character note is cut to 140 runes":
    var long = ""
    for _ in 0 ..< 400:
      long.add("a")
    let plan = parsePlan($ %*{"dispatch": 80, "note": long}, defaultPlan())
    check plan.note.runeLen == MaxNoteRunes

  test "a say whose 32nd and 33rd runes are a 4-byte emoji cuts on the rune":
    ## The bug this pins: a BYTE truncation splits the emoji, the replay
    ## renders in a browser and then fails a strict UTF-8 parser.
    var say = ""
    for _ in 0 ..< 31:
      say.add("x")
    say.add("\xF0\x9F\x9A\x9B")     # U+1F69B, a 4-byte truck
    say.add("\xF0\x9F\x9A\xA6")     # U+1F6A6, a 4-byte traffic light
    check say.runeLen == 33
    let plan = parsePlan($ %*{"dispatch": 80, "say": say}, defaultPlan())
    check plan.say.runeLen == MaxSayRunes
    check validateUtf8(plan.say) == -1
    ## And it still round-trips through the JSON writer and reader.
    let encoded = $planJson(plan)
    check validateUtf8(encoded) == -1
    let decoded = parseJson(encoded)
    check decoded["say"].getStr() == plan.say
    check decoded["say"].getStr().runeLen == MaxSayRunes

  test "the whole recorded string set is rune-truncated":
    var wide = ""
    for _ in 0 ..< 500:
      wide.add("\xE2\x9C\x93")      # U+2713, 3 bytes
    check clipRunes(wide, 140).runeLen == 140
    check validateUtf8(clipRunes(wide, 140)) == -1
    check cleanLine("a\nb\tc", 140) == "a b c"
    check clipRunes("short", 140) == "short"
    check clipRunes("anything", 0) == ""

suite "derived coefficients":
  test "replanQueue spans 3..13 across the patience range":
    var plan = defaultPlan()
    plan.patience = 0
    check replanQueue(plan) == 3
    plan.patience = 100
    check replanQueue(plan) == 13
    for patience in 0 .. 100:
      plan.patience = patience
      check replanQueue(plan) in 3 .. 13

  test "activeCap spans 0..fleetSize and releasePerStep spans 1..6":
    var plan = defaultPlan()
    for dispatch in 0 .. 100:
      plan.dispatch = dispatch
      check activeCap(plan, 50) in 0 .. 50
    plan.dispatch = 0
    check activeCap(plan, 50) == 0
    plan.dispatch = 100
    check activeCap(plan, 50) == 50
    for spread in 0 .. 100:
      plan.spread = spread
      check releasePerStep(plan) in 1 .. 6
    plan.spread = 0
    check releasePerStep(plan) == 6
    plan.spread = 100
    check releasePerStep(plan) == 1

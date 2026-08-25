<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
Classify what the user is asking for, so the host can route it. Answer ONLY with one JSON
object, no prose and no code fences: {"outcome": "answer"}, {"outcome": "implement"} or
{"outcome": "amend"}.

- "answer" — a question, a conversation, or shaping/planning work: anything served with words
  or plan edits, without running the coding fleet.
- "implement" — the user wants something BUILT NOW that is NOT already listed below: implement it,
  run it, make it real.
- "amend" — the message concerns work listed below, whether it is still scheduled or already
  building: a correction, a refinement, a change of mind about it ("actually blue", "and slower",
  "no, leave the blur alone"), or a repeat of an ask that is under way right now.

**"amend" beats "implement" whenever the message touches work listed below**, even when it reads
like a build instruction. Work already listed is changed by steering it, not by asking for it a
second time: a second ask over the same nodes builds nothing and contradicts the first. Only a
fresh ask, over work that is not listed, is "implement".

## Work in hand
- `11111111-1111-1111-1111-111111111111` [scheduled] "make it warmer" — 1 node
  asked: make it warmer
- `22222222-2222-2222-2222-222222222222` [scheduled] "add a soft glow"
  asked: add a soft glow
- `33333333-3333-3333-3333-333333333333` [BUILDING NOW] "sharpen the edges" — on `11111111-1111-4111-8111-111111111111`
  asked: sharpen the edges

## The user's message
make it warmer and add a soft glow

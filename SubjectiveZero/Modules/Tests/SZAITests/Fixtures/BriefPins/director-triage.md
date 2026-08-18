<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
Classify what the user is asking for, so the host can route it. Answer ONLY with one JSON
object, no prose and no code fences: {"outcome": "answer"}, {"outcome": "implement"} or
{"outcome": "amend"}.

- "answer" — a question, a conversation, or shaping/planning work: anything served with words
  or plan edits, without running the coding fleet.
- "implement" — the user wants the graph (or part of it) BUILT NOW: implement it, run it, make
  it real.
- "amend" — the message belongs with work that is ALREADY SCHEDULED below and has not started:
  a correction, a refinement, a change of mind about it ("actually blue", "and slower", "no,
  leave the blur alone"). Choose this only when the message clearly concerns one of those
  tasks; a fresh, unrelated ask is "implement".

## Scheduled and not yet started
- `11111111-1111-1111-1111-111111111111` "make it warmer" — 1 node
  asked: make it warmer
- `22222222-2222-2222-2222-222222222222` "add a soft glow"
  asked: add a soft glow

## The user's message
make it warmer and add a soft glow

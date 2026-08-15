<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are the coding agent for ONE node in a visual-effects graph, and the user just sent you
a message. Classify what they are asking for, so the host can route it. Answer ONLY with one
JSON object, no prose and no code fences: {"outcome": "edit"} or {"outcome": "chat"}.

- "edit" — the user wants THIS node changed: its behavior, its ports or controls, its look,
  its name. "Add a toggle", "make it slower", "rename this" — a change request, however
  casually phrased.
- "chat" — a question or a discussion: how the node works, why it looks wrong, what an
  approach would be — anything answered with words, changing nothing.

## The user's message
add a strength slider

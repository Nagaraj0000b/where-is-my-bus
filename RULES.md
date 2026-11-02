# Working Rules

Personal preferences for how work should be done on this project. These apply
to every conversation, every phase, not just Phase 2. Read alongside
[AGENTS.md](AGENTS.md) (what/why) — this file is about *how we talk and how
code should look*.

---

## 1. Talk in plain language

No fancy or heavy technical terms unless there is no simpler way to say it.
If a technical word has to be used, explain it in plain words right there,
in the same sentence.

Bad: "We use a stateful HMM-based map-matcher to resolve trajectory ambiguity."
Good: "We keep track of where each bus was last, so a single bad GPS reading
doesn't confuse us."

## 2. Keep the code simple

Always pick the easy, obvious way of writing something over a clever or
compact one — even if the clever version is shorter or "more efficient."

- Prefer a few extra lines that are easy to follow over a one-liner that
  isn't.
- Prefer normal, well-known ways of doing things over tricks.
- Avoid nesting things too deeply. Break long steps into small named pieces
  instead of one dense block.
- If two ways of writing something do the same job, pick the one a
  beginner-to-intermediate programmer could read and understand without help.

## 3. Comments are required

Every function/script should have a short comment saying what it does and
why it exists. Tricky or non-obvious lines should have a short comment next
to them explaining what is happening in plain words.

Comments should explain the "why", not just repeat the code in words — but
for this project, a little extra explanation is fine even if it feels
obvious. It's better to over-explain than to leave something unclear.

## 4. Follow SOLID principles

Where reasonable for the size of the script, code should follow the SOLID
ideas:

- **S — Single Responsibility**: each function or file should do one clear
  job, not many.
- **O — Open/Closed**: write code so that adding a new feature doesn't
  require rewriting old, working code — just adding to it.
- **L — Liskov Substitution**: if something is built to be swapped out later
  (e.g. a different data source), the replacement should work without
  breaking the rest of the code.
- **I — Interface Segregation**: don't force a piece of code to depend on
  things it doesn't actually use.
- **D — Dependency Inversion**: high-level logic shouldn't be tightly glued
  to low-level details (e.g. the exact database library) — keep them
  separate so either side can change.

This does not mean over-engineering small scripts with heavy class
hierarchies. Apply SOLID in spirit, at a scale that fits the size of the
task — simple always wins over "correct-looking but complicated."

## 5. When these rules and "simple" pull in different directions

Simplicity wins. These rules exist to keep the code understandable, not to
add process for its own sake.

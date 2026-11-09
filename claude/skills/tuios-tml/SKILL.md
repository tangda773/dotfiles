---
name: tuios-tml
description: "Use when $TUIOS_ENV is 1 and the person asks you to run tests or benchmarks, compare packages or options, or check status. Load this skill before running anything: its body says how to show the answer as a tuios TML surface instead of text or a Markdown table. Not for answers that are a path or one sentence."
---

Run `printenv TUIOS_ENV` first. Go on only if it prints `1`. If the
command is blocked, needs approval, prints nothing or prints anything
else, stop using this skill: run no `tuios` command and answer in text.
`tuios` reaches the person's session even from outside a pane, so
guessing shows them a surface they did not ask for.

Decide now, before you run anything:
- If the answer will have counts, rows, timings or a comparison, it goes in a
  surface, even when it is short or all green. Do not fall back to text
  because it is small.
- A Markdown table in chat is what this skill replaces.
- A path or a one-sentence answer stays in text.

Run `tuios --skill tml` and follow it, with these extra rules:

- Put buttons outside `tabs`, so their keys work on every tab.
- Use `select="none"` on a `table` or `list` unless you handle `on-select`.

Then:
1. Write the `.tml` file under `.tuios/`.
2. `tuios tml validate FILE` and `tuios tml render FILE --width 80`; fix and re-render.
3. `tuios tml show FILE --wait`. Only exit 0 is the person's answer.

For a single yes/no question, `tuios ask-human` is enough.

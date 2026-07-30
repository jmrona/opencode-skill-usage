---
description: How your skills are actually being used — routing leaks, fallbacks, dead skills
# Pin a cheap, fast model here if you like — reading a handful of small tables and
# writing a few paragraphs does not need your best one. Left unset so it uses your
# current model out of the box.
# model: anthropic/claude-haiku-4-20250514
---

Below is a report generated from opencode's own SQLite store. It is retroactive: it
covers history that already exists, not data collected since some plugin was installed.

Optionally pass a number of days to narrow the window (`/skill-usage 30`); with no
argument it covers all history.

!`bash ~/.config/opencode/scripts/skill-usage.sh $ARGUMENTS`

The report above is already visible to the user — it is part of this prompt, not
something you need to relay. **Do not reproduce any of its tables.** Repeating them
would only duplicate what is on screen, and a model retyping a table is a good way
to introduce numbers that were never in it.

Write only a short commentary: a handful of paragraphs, leading with whatever is
most worth acting on. Cite figures from the tables in prose where they support a
point.

What to look for, and how to read it honestly:

- **Routing leaks** are the highest-value finding when present. A skill that
  declares a model in its frontmatter but gets invoked through the native `skill`
  tool runs inline on the session model, which is exactly what the routing was
  meant to avoid. Quote the leak count and the fix: deny that skill in
  `permission.skill` so only the routed tool remains. Ignore `native_before`
  entirely — those calls predate routing for that skill and are not a problem.

- **Fallbacks.** In the model table, more than one row for a skill means the
  primary model was unreachable or failed some of the time. A local model serving
  a small fraction of its own skill's calls usually means the local server is down
  more often than assumed — worth saying plainly.

- **Error rates.** Flag anything above roughly 5%, and say what it most likely is
  (a failing provider, a skill whose prompt does not fit its model). Do not
  speculate beyond what the data supports.

- **Never used.** These are safe to question, but ask rather than assert: a skill
  might be new, or might be losing its trigger to another skill with an
  overlapping description. Where two installed skills plainly cover the same
  ground and only one ever fires, say so — that is a description problem, not a
  usage problem.

- **Dormant.** Be careful here. Frequency is not value: a skill used twice a year
  at exactly the right moment earns its place. Only suggest removing something
  when its disuse looks like abandonment of a whole workflow (several related
  skills going quiet on the same date), and say which skills moved together.

- **Small samples.** If a skill only started being routed days ago, say the sample
  is too small rather than drawing a conclusion from it.

Suggest changes; do not make them. If a recommendation involves editing
`opencode.json` or deleting a skill, describe it and let the user decide.

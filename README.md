# opencode-skill-usage

**A `/skill-usage` command for [opencode](https://opencode.ai)** that tells you which of your skills are actually being used, which ones are quietly bypassing their configured model, and which have been dead for months.

It reads opencode's own SQLite store. There is no plugin, no instrumentation and nothing to install ahead of time — which means the very first run already covers your **entire history**, not just what happened after you set it up.

```
/skill-usage         # all history
/skill-usage 30      # last 30 days
```

## Why this exists rather than a plugin

The obvious way to answer "which skills do I actually use?" is to write a plugin that logs every invocation. That works, but it starts from zero: you install it, then wait weeks for enough data to say anything, and you learn nothing about the six months you already have.

opencode already records all of it. Every tool call lands in the `part` table as a JSON blob, including which skill ran, whether it errored, how long it took and — for skills routed to a specific model — which model actually served it. The question was never "how do I collect this data", it was "how do I look at it".

So this is a shell script wrapped in a command. It answers the same questions a plugin would, retroactively, and it stops running the moment it has printed the report.

## What it reports

**Routing leaks.** Only shown if something is actually routing skills — this section and the model breakdown below are omitted entirely when nothing registers `skill_*` tools, which is the common case. If you use something like [skill-model-router](https://github.com/jmrona/skill-model-router-plugin) to pin a model per skill, that skill is still reachable through opencode's native `skill` tool — which runs it inline on the session model, quietly defeating the routing. This section counts how often that happened, and only counts calls made *after* routing became active for that skill, so historic calls from before you set it up are shown separately rather than inflating the number. The fix is a `deny` entry in `permission.skill`.

**Usage.** Every skill, split by how it was invoked (`native` vs `routed`), with its scope, call counts, error rate, mean duration and last use. A scope of `other` means the skill ran but is not in either directory scanned — it came from a plugin, or from a different project.

**Model that actually served each routed skill.** More than one row for a skill means fallbacks happened, and the split tells you how often. This is how you find out that the local model you carefully configured has been serving a quarter of its own calls because the server keeps going down. The model is resolved from the tool part's metadata, falling back to the child session row and then to the child session title.

**Installed but not used.** Every installed skill with no invocation in the window, computed against the skills actually on disk. opencode searches six locations, and this reads all of them:

| Scope | Path |
|---|---|
| `global` | `~/.config/opencode/skills/` |
| `global:claude` | `~/.claude/skills/` |
| `global:agents` | `~/.agents/skills/` |
| `project` | `.opencode/skills/` |
| `project:claude` | `.claude/skills/` |
| `project:agents` | `.agents/skills/` |

Project locations are checked at every level from the working directory up to the git worktree root, which is where opencode stops walking. A name found in more than one place is merged into a single row with the scopes joined — a duplicate opencode itself warns about, and picks one of.

Two columns exist to keep an important distinction visible: `calls_ever` and `last_used_ever` are computed over your whole history regardless of the window. So with `/skill-usage 30`, a skill last used two months ago appears here with the date it was last used, rather than being lumped in with skills that have never run at all. The heading changes to match — "never used" is only claimed when the window is your entire history.

**Dormant.** Used within the window, but not in the last two weeks, with days idle. Narrowing the window moves skills out of here and into the unused table, so the two never double-report.

## Install

Copy the two directories into your opencode config directory — `~/.config/opencode/` for a global install, or `.opencode/` inside a project:

```sh
git clone https://github.com/jmrona/opencode-skill-usage.git /tmp/skill-usage
cp -r /tmp/skill-usage/commands /tmp/skill-usage/scripts ~/.config/opencode/
chmod +x ~/.config/opencode/scripts/skill-usage.sh
```

Restart opencode and type `/skill-usage`.

Requires `bash` and the `sqlite3` CLI, which ships with macOS and most Linux distributions.

The report is printed straight into the conversation and the model only adds a
commentary on top. It used to run in a subtask to keep the tables out of context,
with the model asked to reproduce the ones worth seeing — that does not work.
Anything you want to *see* from inside a subtask has to be retyped by the model,
and models summarise tables instead of copying them, or copy them with numbers
that drift. Visible and out-of-context are mutually exclusive here, so the tables
are printed deterministically by the script.

There is a commented-out `model:` line in the frontmatter if you want to pin a
cheap model for the commentary; reading a few small tables and writing a couple of
paragraphs does not need your best one.

You can skip the command entirely and run the script on its own, which is the lightest option of all:

```sh
bash ~/.config/opencode/scripts/skill-usage.sh 30
```

## How it works

The script locates `opencode.db` by checking `$OPENCODE_DB`, then `$XDG_DATA_HOME/opencode/`, `~/.local/share/opencode/`, macOS's Application Support and `~/.config/opencode/`, searching as a last resort. It opens the database **read-only**, so it is safe to run while opencode is going.

Everything happens in one `sqlite3` process: one pass over `part` materialises a temp table of skill invocations, and the five report sections query that. An earlier version opened the database once per section and re-scanned every time, which took 5.6s on an 880MB store against 0.36s now.

Most of the remaining win comes from a `data LIKE '%skill%'` prefilter that avoids parsing JSON for the parts that could not possibly be skill calls. That filter is deliberately loose: matching the exact serialisation is no faster, and would break silently if the JSON were ever written with spaces after the colons — the report would show zero skill usage rather than failing, which is the worst way for a report to be wrong. Since the query already requires the tool to be named `skill` or `skill_*`, the substring cannot exclude a real match.

## Reading the output honestly

A usage report is easy to over-trust, so the command's prompt is explicit about a few traps, and they are worth knowing whether or not you use the commentary:

- **Frequency is not value.** A skill invoked twice a year at exactly the right moment earns its place. Only treat disuse as a signal when a whole workflow goes quiet at once — several related skills with the same last-used date.
- **`native_before` is not a leak.** Those calls predate routing for that skill. Only the `leaks` column means something is wrong now.
- **Small samples say nothing.** A skill routed for three days does not have a fallback rate yet.
- **A skill that never fires may be losing its trigger**, not sitting idle. If two installed skills cover the same ground and only one ever runs, that is a description problem, and deleting the loser hides it rather than fixing it.

## Limitations

- Project locations are resolved relative to the working directory, walking up to the git worktree root. Running the script from outside a repository checks only that directory. `PROJECT_SKILLS_DIR` overrides the walk with a single explicit path.
- Reads opencode's internal schema (`part.data` JSON, `session`). Nothing here is a public API, so a future opencode release could change the shape and break the queries.
- Skill names are recovered from routed tool names by turning underscores back into dashes, since `skill_quick_explain` is how `quick-explain` is registered. A skill with a genuine underscore in its name would be mislabelled.
- Duration and error columns reflect what opencode recorded; a skill that failed in a way opencode did not mark as an error will not show up as one.

## Licence

MIT

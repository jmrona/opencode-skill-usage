#!/usr/bin/env bash
# skill-usage.sh — report on how opencode skills are actually being used.
#
# Reads opencode's SQLite store directly (read-only). Everything here is
# retroactive: it works on history that already exists, with no instrumentation.
#
# Usage: skill-usage.sh [days]     (default: all history)
#
# Performance note: this runs as a single sqlite3 process that materialises one
# temp table and then queries it five times. The earlier version opened the
# database once per section and re-scanned `part` each time, which cost ~5.6s on
# an 880MB store; this is ~5x less work. The `data LIKE '%skill%'` prefilter
# matters just as much — it skips JSON parsing on every part that isn't a skill
# call, which is the overwhelming majority of them (0.82s -> 0.32s on that store).
#
# That prefilter is deliberately loose. Matching the exact serialisation
# (`'%"tool":"skill%'`) is no faster and breaks silently if the JSON is ever
# written with spaces after the colons — the report would show zero skill usage
# rather than failing. Since the WHERE below already requires the tool to be
# named `skill` or `skill_*`, the substring `skill` cannot exclude a real match.

set -uo pipefail

DAYS="${1:-0}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.config/opencode/skills}"

# --- locate the database -----------------------------------------------------
find_db() {
  local candidates=(
    "${OPENCODE_DB:-}"
    "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
    "$HOME/.local/share/opencode/opencode.db"
    "$HOME/Library/Application Support/opencode/opencode.db"
    "$HOME/.config/opencode/opencode.db"
  )
  for c in "${candidates[@]}"; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  find "$HOME/.local/share" "$HOME/Library/Application Support" "$HOME/.config" \
       -maxdepth 3 -name 'opencode.db' -print -quit 2>/dev/null
}

DB="$(find_db)"
if [ -z "$DB" ]; then
  echo "Could not find opencode.db. Set OPENCODE_DB=/path/to/opencode.db and re-run." >&2
  exit 1
fi

command -v sqlite3 >/dev/null || { echo "sqlite3 not found on PATH." >&2; exit 1; }

# Time filter. state.time.start is epoch milliseconds.
if [ "$DAYS" -gt 0 ] 2>/dev/null; then
  SINCE="(strftime('%s','now','-${DAYS} day') * 1000)"
  WINDOW="last ${DAYS} days"
else
  SINCE="0"
  WINDOW="all history"
fi

# Installed skills as a SQL VALUES list, so "never used" is computed rather than
# eyeballed. Directories with a SKILL.md only; _shared is not a skill.
installed_values() {
  local first=1 n
  for d in "$SKILLS_DIR"/*/; do
    n="$(basename "$d")"
    [ "$n" = "_shared" ] && continue
    [ -f "$d/SKILL.md" ] || continue
    [ $first -eq 1 ] && first=0 || printf ","
    printf "('%s')" "${n//\'/\'\'}"
  done
  [ $first -eq 1 ] && printf "('')"
}
INSTALLED="$(installed_values)"

echo "# Skill usage report"
echo
echo "Window: **$WINDOW** · database: \`$DB\` · generated $(date '+%Y-%m-%d %H:%M')"

sqlite3 -readonly "$DB" <<SQL
.mode markdown

CREATE TEMP TABLE calls AS
SELECT
  CASE WHEN json_extract(data,'\$.tool') = 'skill'
       THEN json_extract(data,'\$.state.input.name')
       ELSE replace(substr(json_extract(data,'\$.tool'), 7), '_', '-') END AS skill,
  CASE WHEN json_extract(data,'\$.tool') = 'skill' THEN 'native' ELSE 'routed' END AS via,
  json_extract(data,'\$.state.status')                    AS status,
  json_extract(data,'\$.state.time.start')                AS t_start,
  json_extract(data,'\$.state.time.end')                  AS t_end,
  json_extract(data,'\$.state.metadata.model.providerID')  AS provider,
  json_extract(data,'\$.state.metadata.model.modelID')     AS model,
  json_extract(data,'\$.state.metadata.sessionId')         AS child_session
FROM part
WHERE data LIKE '%skill%'
  AND json_extract(data,'\$.type') = 'tool'
  AND (json_extract(data,'\$.tool') = 'skill'
       OR json_extract(data,'\$.tool') LIKE 'skill\_%' ESCAPE '\')
  AND json_extract(data,'\$.state.time.start') >= $SINCE;

CREATE TEMP TABLE routed_since AS
  SELECT skill, MIN(t_start) AS t0 FROM calls WHERE via = 'routed' GROUP BY skill;

CREATE TEMP TABLE routing_from AS SELECT MIN(t0) AS t0 FROM routed_since;

CREATE TEMP TABLE installed(skill TEXT);
INSERT INTO installed(skill) VALUES $INSTALLED;

.mode list
-- The two routing sections only mean anything when something is registering
-- skill_* tools, such as skill-model-router. Without that, printing the headings
-- unconditionally left a stray "Fix: ..." line under an empty section, reading as
-- broken rather than as not applicable. List mode emits plain lines, and the
-- WHERE EXISTS drops the block entirely when no routed call has ever been seen.
--
-- Three traps here, all of which bit while writing it:
--   1. One multi-line literal, not a UNION ALL chain: in a chain, WHERE binds
--      only to the final branch, so every earlier line prints regardless.
--   2. A comment must not sit directly before a dot-command, which leaves the
--      parser mid-statement and the dot-command is then read as SQL.
--   3. No backticks anywhere in this heredoc. It is unquoted so that SINCE and
--      INSTALLED interpolate, which means bash runs backticked text as a command.
SELECT '
## Routing leaks

Skills with routing metadata that were nevertheless invoked through the native
skill tool, which runs them inline on the session model. Only calls made after
routing became active for that skill count as leaks; earlier ones predate the
router and are shown separately.
' WHERE EXISTS (SELECT 1 FROM routed_since);
.mode markdown

SELECT
  c.skill                                                            AS skill,
  date(COALESCE(r.t0, g.t0)/1000,'unixepoch')                        AS routing_since,
  SUM(CASE WHEN c.via='routed' THEN 1 ELSE 0 END)                    AS routed,
  SUM(CASE WHEN c.via='native' AND c.t_start <  COALESCE(r.t0,g.t0) THEN 1 ELSE 0 END) AS native_before,
  SUM(CASE WHEN c.via='native' AND c.t_start >= COALESCE(r.t0,g.t0) THEN 1 ELSE 0 END) AS leaks,
  date(MAX(CASE WHEN c.via='native' AND c.t_start >= COALESCE(r.t0,g.t0) THEN c.t_start END)/1000,'unixepoch') AS last_leak
FROM calls c
LEFT JOIN routed_since r ON r.skill = c.skill
CROSS JOIN routing_from g
WHERE c.skill IN (SELECT skill FROM routed_since)
GROUP BY c.skill
HAVING leaks > 0
ORDER BY leaks DESC;

.mode list
SELECT '
Fix: deny the leaking skill in permission.skill so only the routed tool remains.
' WHERE EXISTS (SELECT 1 FROM routed_since);
.mode markdown

.print ''
.print '## Usage'
.print ''

SELECT
  skill,
  via,
  COUNT(*)                                                                    AS calls,
  SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END)                           AS errors,
  ROUND(100.0 * SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) / COUNT(*), 1) AS err_pct,
  ROUND(AVG(t_end - t_start)/1000.0, 1)                                       AS avg_s,
  date(MAX(t_start)/1000,'unixepoch')                                         AS last_used
FROM calls
GROUP BY skill, via
ORDER BY calls DESC;

.mode list
SELECT '
## Model that actually served each routed skill

More than one row for a skill means fallbacks happened; the split shows how often.
The model is resolved from the tool part metadata, then the child session row,
then the child session title, which the router formats as skill:name (provider/model).
' WHERE EXISTS (SELECT 1 FROM routed_since);
.mode markdown

SELECT
  c.skill                                       AS skill,
  COALESCE(
    c.provider || '/' || c.model,
    s.model,
    CASE WHEN s.title LIKE '%(%)'
         THEN substr(s.title, instr(s.title,' (') + 2,
                     length(s.title) - instr(s.title,' (') - 2) END,
    '(not recorded)'
  )                                             AS model_ran,
  COUNT(*)                                      AS runs
FROM calls c
LEFT JOIN session s ON s.id = c.child_session
WHERE c.via = 'routed'
GROUP BY 1, 2
ORDER BY skill, runs DESC;

.print ''
.print '## Installed but never used'
.print ''

SELECT i.skill AS skill
FROM installed i
WHERE i.skill <> ''
  AND i.skill NOT IN (SELECT skill FROM calls WHERE skill IS NOT NULL)
ORDER BY 1;

.print ''
.print '## Dormant (used, but not recently)'
.print ''

SELECT
  c.skill                                                          AS skill,
  COUNT(*)                                                         AS calls,
  date(MAX(c.t_start)/1000,'unixepoch')                            AS last_used,
  CAST((strftime('%s','now') - MAX(c.t_start)/1000) / 86400 AS INT) AS days_idle
FROM calls c
JOIN installed i ON i.skill = c.skill
GROUP BY c.skill
HAVING days_idle >= 14
ORDER BY days_idle DESC;

.print ''
.print 'Skills used here but missing from the installed list are project-level or came with a plugin.'
SQL

#!/bin/bash
# Update Life Recorder summaries, but only wake Claude when new speech arrived.
# Clips are filed under the day they were recorded, so a late upload still lands in the right file.
# Usage: summarize.sh [YYYY-MM-DD ...]   (a day argument reconciles that whole day and leaves the marker alone)
set -euo pipefail
D=${LIFE_RECORDER_DIR:-$HOME/.local/share/life-recorder}
CLAUDE=${CLAUDE:-$(command -v claude || echo "$HOME/.local/share/mise/installs/claude/latest/claude")}
# Your own summary rules (language, segmentation, names). They name real people, so they stay out of the repo.
CONVENTIONS=${CONVENTIONS:-$D/summary-conventions.md}
speech="status='complete' and length(transcript)>0"
latest=$(sqlite3 "$D/inbox.sqlite3" "select coalesce(max(received),0) from chunks where $speech")
if [ $# -gt 0 ]; then
  days=$*
  prev=0
else
  prev=$(cat "$D/.summarized-through" 2>/dev/null || date -d 'today 00:00' +%s 2>/dev/null || date -j -f %T 00:00:00 +%s)  # GNU, then BSD/macOS
  [ "$latest" = "$prev" ] && exit 0
  # '+8 hours' = Asia/Taipei (no DST); started is stored in UTC.
  days=$(sqlite3 "$D/inbox.sqlite3" "select distinct date(started,'+8 hours') from chunks where $speech and received > $prev order by 1")
fi

cd "$D"
for day in $days; do
  # What the file already covers, so a run cannot write a second section for the same minute.
  covered=$(grep -oE "^## [0-9]{2}:[0-9]{2}" "$D/summaries/$day.md" 2>/dev/null | awk "{print \$2}" | sort | paste -sd, - || true)
  last=$(grep -oE "^## [0-9]{2}:[0-9]{2}" "$D/summaries/$day.md" 2>/dev/null | awk "{print \$2}" | sort | tail -1 || true)
  "$CLAUDE" -p \
    --allowedTools "Read" "Bash(sqlite3:*)" "mcp__claude_ai_Google_Calendar__list_events" \
      "Edit(/$D/summaries/**)" "Edit(/$D/vocabulary.md)" \
    -- "Read the conventions in $CONVENTIONS first and follow them.
You are updating the summary for $day (Asia/Taipei): only clips whose started time falls on that day belong in it.
The file already has sections for these times: ${covered:-none} (the last is ${last:-none}). Summarize only clips that started after ${last:-00:00}, with two exceptions: you may edit an existing section in place to correct or extend it, and clips that were uploaded late (received > $prev in unix seconds, but started at or before ${last:-00:00}) must still be covered, by folding them into the existing section for that time or inserting a new section at the right place. Never add a second section for a time that already has one, and keep the sections in clock order.
Check the Life Recorder inbox for clips recorded since the last summary update. Query $D/inbox.sqlite3 (table chunks) for clips with transcripts newer than what $D/summaries/$day.md already covers (create it with a '# $day' heading if missing; after-midnight clips belong to the new day). If there is meaningful new speech, update that file: segment by Google Calendar meetings (list_events for $day, Asia/Taipei) and silent gaps, apply the glossary at $D/vocabulary.md, keep sections in chronological order, and keep it phone-length. If nothing new or only noise, change nothing. Reply with one line saying what you did."
done
[ $# -gt 0 ] || echo "$latest" > "$D/.summarized-through"

#!/bin/bash
# Update today's Life Recorder summary, but only wake Claude when new speech arrived.
set -euo pipefail
D=$HOME/.local/share/life-recorder
latest=$(sqlite3 "$D/inbox.sqlite3" "select coalesce(max(received),0) from chunks where status='complete' and length(transcript)>0")
[ "$latest" = "$(cat "$D/.summarized-through" 2>/dev/null)" ] && exit 0

today=$(TZ=Asia/Taipei date +%F)
cd "$D"
# What the file already covers, so a run cannot write a second section for the same minute.
covered=$(grep -oE "^## [0-9]{2}:[0-9]{2}" "$D/summaries/$today.md" 2>/dev/null | awk "{print \$2}" | sort | paste -sd, -)
last=$(grep -oE "^## [0-9]{2}:[0-9]{2}" "$D/summaries/$today.md" 2>/dev/null | awk "{print \$2}" | sort | tail -1)
"$HOME/.local/share/mise/installs/claude/latest/claude" -p \
  --allowedTools "Read" "Bash(sqlite3:*)" "mcp__claude_ai_Google_Calendar__list_events" \
    "Edit(/$D/summaries/**)" "Edit(/$D/vocabulary.md)" \
  -- "Read the conventions in $HOME/.claude/projects/-home-unayung-Projects/memory/life-recorder-summary-conventions.md first and follow them.
The file already has sections for these times: ${covered:-none} (the last is ${last:-none}). Summarize only clips that started after ${last:-00:00}, with one exception: you may edit an existing section in place to correct or extend it. Never add a second section for a time that already has one, and keep the sections in clock order.
Check the Life Recorder inbox for clips recorded since the last summary update. Query $D/inbox.sqlite3 (table chunks) for clips with transcripts newer than what $D/summaries/$today.md already covers (create it with a '# $today' heading if missing; after-midnight clips belong to the new day). If there is meaningful new speech, update that file: segment by Google Calendar meetings (list_events for today, Asia/Taipei) and silent gaps, apply the glossary at $D/vocabulary.md, keep sections in chronological order, and keep it phone-length. If nothing new or only noise, change nothing. Reply with one line saying what you did."
echo "$latest" > "$D/.summarized-through"

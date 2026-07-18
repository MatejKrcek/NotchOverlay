#!/bin/sh
# Claude Code hook: uloží event JSON (stdin) + TERM_PROGRAM do fronty,
# kterou čte NotchOverlay. Nesmí nikdy selhat ani zdržovat (fire-and-forget).
d="$HOME/.claude/vibe-events"
mkdir -p "$d" 2>/dev/null || exit 0
{
  cat
  printf '\n{"env_term":"%s"}\n' "$TERM_PROGRAM"
} > "$d/$(date +%s%N)-$$.evt" 2>/dev/null
exit 0

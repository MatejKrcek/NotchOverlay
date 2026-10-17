#!/bin/sh
# Claude Code hook: uloží event JSON (stdin) + TERM_PROGRAM do fronty,
# kterou čte NotchOverlay. Nesmí nikdy selhat ani zdržovat (fire-and-forget).
# Zapisuje přes dočasný soubor + mv, aby appka (hlídá adresář přes vnode
# event) nikdy nepřečetla rozepsaný soubor.
d="$HOME/.claude/vibe-events"
mkdir -p "$d" 2>/dev/null || exit 0
name="$(date +%s%N)-$$"
{
  cat
  printf '\n{"env_term":"%s"}\n' "$TERM_PROGRAM"
} > "$d/.$name.tmp" 2>/dev/null && mv -f "$d/.$name.tmp" "$d/$name.evt" 2>/dev/null
exit 0

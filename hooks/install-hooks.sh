#!/bin/zsh
# Zaregistruje vibe-event.sh do ~/.claude/settings.json pro eventy
# SessionStart, Notification, Stop a SessionEnd. Idempotentní; před změnou
# udělá zálohu settings.json.vibe-backup. Odinstalace: smazat záznamy
# s "vibe-event.sh" z "hooks" v ~/.claude/settings.json (nebo vrátit zálohu).
set -e
HOOK="$(cd "$(dirname "$0")" && pwd)/vibe-event.sh"
chmod +x "$HOOK"
python3 - "$HOOK" <<'EOF'
import json, os, shutil, sys
hook_cmd = sys.argv[1]
path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    shutil.copy(path, path + ".vibe-backup")
    with open(path) as f:
        settings = json.load(f)
hooks = settings.setdefault("hooks", {})
for event in ["SessionStart", "Notification", "Stop", "SessionEnd"]:
    entries = hooks.setdefault(event, [])
    already = any(
        "vibe-event.sh" in h.get("command", "")
        for e in entries for h in e.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [{"type": "command", "command": hook_cmd, "timeout": 5}]})
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("Hooky nainstalovány do ~/.claude/settings.json (záloha: settings.json.vibe-backup)")
EOF

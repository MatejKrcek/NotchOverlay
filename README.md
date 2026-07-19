# NotchOverlay

![Kompaktní stav v notchi](docs/compact.png)

![Expandovaný panel se sessions](docs/expanded.png)

## Instalace (nativní appka na pozadí)

Jedním příkazem (stačí Xcode Command Line Tools):

```sh
curl -fsSL https://raw.githubusercontent.com/MatejKrcek/NotchOverlay/main/install.sh | bash
```

Nebo z naklonovaného repa:

```sh
./install.sh   # build → /Applications/NotchOverlay.app + LaunchAgent
               # (start po přihlášení, auto-restart po pádu)
```

Ukončení: pravý klik na island → Quit (zůstane vypnutá do dalšího přihlášení).
Odinstalace: viz komentář v install.sh.

Vývoj bez instalace:

```sh
./build.sh          # kompilace (swiftc; SPM je na tomto stroji rozbité)
./bin/NotchOverlay  # spuštění na zkoušku
```

## Funkce

- **Kompaktní stav v notchi** — stavové tečky agentů vlevo, vpravo „5h X %"
  (reálná spotřeba 5h okna z API) nebo ⚠ N, když něco čeká na tebe.
  Na displeji bez notche plovoucí lišta.
- **Hover → expanze** — panel se rozbalí pod notch: hlavička s kvótami
  (5h okno + týdenní limit v %, časy resetů) a řádek na session
  (název z ai-title, stav, projekt, branch, model, čas od poslední aktivity).
- **Reálné kvóty** — OAuth token z Keychain („Claude Code-credentials")
  → `api.anthropic.com/api/oauth/usage`, refresh každých 60 s. Token
  neopouští stroj jinam než na API Anthropicu. Debug: `~/.claude/vibe-quota-debug.txt`.
- **Barvy**: modrá = pracuje · zelená = hotovo · oranžová = potřebuje tvou
  akci (permission/otázka/zaseknuto) · červená = fail (API error).
- **Klik na řádek → jump do terminálu** (TERM_PROGRAM z hooků, jinak první
  běžící známý terminál: iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty,
  Terminal, VS Code/Cursor).
- **Allow/Deny tlačítka** u permission requestů — aktivují terminál a pošlou
  klávesu do dialogu (1 = povolit, Esc = zamítnout; vyžaduje oprávnění
  Automation pro System Events).
- **8-bit zvuky** — syntetizovaná čtvercová vlna (start, permission, otázka,
  hotovo, deny). Defaultně vypnuté; zapnutí: pravý klik → Sounds.
- **Non-activating overlay** — panel nikdy nesebere focus a nekrade aktivaci.

## Zdroje dat

1. **Pasivně**: tail transkriptů `~/.claude/projects/**/*.jsonl` každých 1,5 s
   (stav ze závěru transkriptu + mtime). Funguje bez jakékoli konfigurace.
2. **Hooky** (přesnější eventy): `hooks/install-hooks.sh` zaregistruje
   `hooks/vibe-event.sh` do `~/.claude/settings.json` pro SessionStart,
   Notification, Stop a SessionEnd. Eventy tečou přes frontu souborů
   `~/.claude/vibe-events/`. **Odinstalace**: vrátit
   `~/.claude/settings.json.vibe-backup` nebo smazat záznamy s `vibe-event.sh`.

Debug: aktuální stav sessions app průběžně zapisuje do `~/.claude/vibe-state.json`.

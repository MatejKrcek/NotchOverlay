# NotchOverlay

**Dynamic Island pro Mac — sleduj svoje AI coding agenty přímo v notchi.**

NotchOverlay promění výřez v displeji MacBooku v živý přehled běžících
Claude Code sessions: barevné tečky říkají, kdo pracuje, kdo skončil a kdo
čeká na tebe, vedle toho tikají reálná procenta tvých rate limitů. Najetím
myší se island rozbalí do panelu s detaily každé session — odtud skočíš
rovnou do správného terminálu, nebo povolíš/zamítneš permission request
jedním klikem, bez přepínání oken. Nativní AppKit, žádné závislosti,
tokeny neopouští tvůj stroj.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-☕-yellow)](https://buymeacoffee.com/matejkrcek)

*English version: [README.md](README.md)*

## Jak to vypadá

Kompaktní stav v notchi — tečky sessions vlevo, spotřeba limitů vpravo:

![Kompaktní stav v notchi](docs/compact.png)

Hover → expandovaný panel se všemi sessions, kvótami a Allow/Deny tlačítky:

![Expandovaný panel se sessions](docs/expanded.png)

## Instalace

### Homebrew (doporučeno)

```sh
brew tap matejkrcek/notchoverlay
brew trust matejkrcek/notchoverlay   # novější Homebrew vyžaduje důvěru cizím tapům
brew install --cask notchoverlay
```

Quarantine flag se smaže automaticky (postflight), není potřeba nic povolovat.

### DMG

Stáhni `NotchOverlay.dmg` z [Releases](https://github.com/MatejKrcek/NotchOverlay/releases)
a přetáhni appku do Applications. Appka je ad-hoc podepsaná, takže ji
Gatekeeper po stažení zablokuje („nelze ověřit vývojáře"). Povolení:

- pravý klik na appku → **Open** → potvrdit **Open** (starší macOS:
  System Settings → Privacy & Security → **Open Anyway**), nebo
- v terminálu: `xattr -cr /Applications/NotchOverlay.app`

### Ze zdrojáků (stačí Xcode Command Line Tools)

```sh
curl -fsSL https://raw.githubusercontent.com/MatejKrcek/NotchOverlay/main/install.sh | bash
```

Nebo z naklonovaného repa:

```sh
./install.sh   # build → /Applications/NotchOverlay.app + LaunchAgent
               # (start po přihlášení, auto-restart po pádu)
```

> Rozdíl: instalace ze zdrojáků přidá i LaunchAgent (appka startuje po
> přihlášení a po pádu se restartuje). Homebrew/DMG appku jen nainstaluje —
> spouštíš ji sám z /Applications.

## První spuštění

1. Otevři **NotchOverlay** z /Applications — ukáže se okno s nastavením
   a v notchi se objeví island. Okno kdykoli otevřeš znovu kliknutím na
   appku nebo **pravým klikem na island**.
2. **Sign in with Claude** (v okně) — kvóty se jinak čtou z credentials
   Claude Code, takže pokud používáš Claude Code, obvykle není potřeba.
3. Při prvním použití **Allow/Deny** tlačítek si macOS řekne o oprávnění
   **Automation** (System Events + tvůj terminál) — povol ho, jinak
   tlačítka nemají jak poslat odpověď do terminálu.
4. Volitelně: `hooks/install-hooks.sh` pro přesnější eventy (viz níže).

## Update

- Homebrew: `brew update && brew upgrade --cask notchoverlay`
- DMG: stáhnout nový z Releases a přepsat appku
- Ze zdrojáků: znovu spustit instalační one-liner

## Odinstalace

```sh
# Homebrew:
brew uninstall --cask notchoverlay

# DMG / zdrojáky:
launchctl bootout gui/$UID/com.matejkrcek.notchoverlay 2>/dev/null
rm -rf /Applications/NotchOverlay.app ~/Library/LaunchAgents/com.matejkrcek.notchoverlay.plist
```

Ukončení bez odinstalace: okno appky → **Quit NotchOverlay** (zůstane
vypnutá do dalšího přihlášení).

## Vývoj bez instalace

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
- **Reálné kvóty** — OAuth token z Keychain (vlastní login, jinak „Claude
  Code-credentials") → `api.anthropic.com/api/oauth/usage`, refresh à 5 min.
  Token neopouští stroj jinam než na API Anthropicu. Debug: `~/.claude/vibe-quota-debug.txt`.
- **Barvy**: modrá = pracuje · zelená = hotovo · oranžová = potřebuje tvou
  akci (permission/otázka/zaseknuto) · červená = fail (API error).
- **Klik na řádek → jump do terminálu** (TERM_PROGRAM z hooků, jinak první
  běžící známý terminál: iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty,
  Terminal, VS Code/Cursor).
- **Allow/Deny tlačítka** u permission requestů — aktivují terminál a pošlou
  klávesu do dialogu (1 = povolit, Esc = zamítnout; vyžaduje oprávnění
  Automation pro System Events).
- **8-bit zvuky** — syntetizovaná čtvercová vlna (start, permission, otázka,
  hotovo, deny). Defaultně vypnuté; zapnutí v nastavení.
- **Non-activating overlay** — panel nikdy nesebere focus a nekrade aktivaci.
- **Nastavení** (klik na appku nebo pravý klik na island; okno na šířku ve dvou
  sloupcích, resizovatelné, pamatuje si velikost) — island on/off,
  velikost islandu (0.7–1.5×), velikost panelu (0.8–1.6×, rozbalený seznam),
  zvuky, tokeny a/nebo odhad spendu per session, kvóta v liště, druhá řádka
  hlavičky (Codex limit z lokálních session dat / Fable 5 limit), účty
  Claude/Codex/Gemini se sign in/out a Quit.
- **Indikace neaktuální kvóty** — appka čte OAuth token Claude Code a sama ho
  nikdy neobnovuje (refresh tokeny rotují). Když token prošel, hodnoty se
  ukazují jako `~12%` s poznámkou „stale" a Keychain se čte každých 30 s,
  dokud si ho Claude Code neobnoví.
- **Codex** — limit okna hlásí jen při přihlášení ChatGPT plánem; u API klíče
  to hlavička řekne místo „no data".

## Zdroje dat

1. **Pasivně**: tail transkriptů `~/.claude/projects/**/*.jsonl` každých 1,5 s
   (stav ze závěru transkriptu + mtime). Funguje bez jakékoli konfigurace.
2. **Hooky** (přesnější eventy): `hooks/install-hooks.sh` zaregistruje
   `hooks/vibe-event.sh` do `~/.claude/settings.json` pro SessionStart,
   Notification, Stop a SessionEnd. Eventy tečou přes frontu souborů
   `~/.claude/vibe-events/`. **Odinstalace**: vrátit
   `~/.claude/settings.json.vibe-backup` nebo smazat záznamy s `vibe-event.sh`.

Debug: aktuální stav sessions app průběžně zapisuje do `~/.claude/vibe-state.json`.

## Kontribuce

Příspěvky vítány! Repo je veřejné, ale pushovat může jen maintainer —
platí standardní GitHub flow:

1. Forkni repo a vytvoř branch.
2. Udělej změnu (`./build.sh` musí projít).
3. Otevři pull request — projdu a mergnu.

## Podpora

Appka je zdarma a open source. Jestli ti šetří čas, můžeš mi koupit kafe:
**[buymeacoffee.com/matejkrcek](https://buymeacoffee.com/matejkrcek)** ☕

---

Developed by **[Matej Krcek](https://www.linkedin.com/in/matejkrcek)** from
**[Kreedl](https://kreedl.com)**.

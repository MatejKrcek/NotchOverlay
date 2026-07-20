# Spend overview v nastavení — design

**Datum:** 2026-07-20
**Stav:** schváleno k implementaci

## Cíl

Do okna nastavení (`MainWindowController`) přidat sekci **SPEND**, která ukazuje
odhad spotřeby za čtyři časová okna: **posledních 24 h, 7 dní, 31 dní a tento
(kalendářní) rok**. V každém okně se zobrazí **počet tokenů i odhad ceny v USD**
rovnocenně.

## Zdroj dat a jeho meze

Data pocházejí z lokálních transkriptů Claude Code:
`~/.claude/projects/*/*.jsonl`. Každý řádek typu `assistant` s polem
`message.usage` nese tokeny (`input_tokens`, `cache_creation_input_tokens`,
`output_tokens`, `cache_read_input_tokens`), `timestamp` a `message.model`.

Dvě vědomá omezení, která se promítnou do UI (poznámka pod sekcí):

1. **Cena je odhad**, ne skutečná fakturace. Používá se stejná hrubá cenová
   tabulka jako v islandu (viz refaktor níže) — nezohledňuje slevy, tier, batch apod.
2. **„Tento rok" je omezený tím, co je na disku.** Claude Code transkripty
   rotuje/maže, takže roční okno pokrývá jen historii, která lokálně existuje
   (často řádově týdny, ne celý rok). Nesnažíme se detekovat, jak moc je useknuté;
   místo toho ukážeme neutrální poznámku „Estimate from local transcripts."

## Komponenty

### 1. `Pricing` (refaktor, `Models.swift`)

Cenová tabulka je dnes privátní v `UsageStats.pricing(for:)`. Vytáhne se do
sdíleného typu, aby ji sdílely `UsageStats` i nový `SpendStats` (jeden zdroj pravdy):

```swift
enum Pricing {
    /// Hrubý odhad ceny za 1M tokenů (input, output, cache read).
    static func rates(for model: String) -> (inp: Double, out: Double, cache: Double)

    /// Odhad ceny v USD z rozpadu tokenů (zachovává dnešní vzorec UsageStats:
    /// input+cache_creation účtováno vstupní sazbou, output výstupní, cache_read cache sazbou).
    static func cost(input: Int, cacheCreation: Int, output: Int,
                     cacheRead: Int, model: String) -> Double
}
```

`UsageStats.ingest(...)` se upraví, aby cenu počítal přes `Pricing.cost(...)`
(chování se nemění — jen se odstraní duplicita).

### 2. `SpendStats.swift` (nový)

Agregátor historické spotřeby, počítaný **na vyžádání** (při otevření okna),
na pozadí, s cache.

Modely:

```swift
struct SpendWindow: Equatable {
    var tokens: Int = 0      // input + cache_creation + output + cache_read
    var costUSD: Double = 0
}

struct SpendSummary: Equatable {
    var last24h  = SpendWindow()
    var last7d   = SpendWindow()
    var last31d  = SpendWindow()
    var thisYear = SpendWindow()
    var computedAt: Date? = nil   // nil = ještě nespočítáno (UI ukáže „…")
}
```

Rozhraní:

```swift
final class SpendStats {
    /// Spočítá summary na pozadí a zavolá completion na main threadu.
    func compute(completion: @escaping (SpendSummary) -> Void)
}
```

Algoritmus `compute`:

1. Urči cutoffy: `now-24h`, `now-7d`, `now-31d`, `startOfYear` (1. 1. lokálně,
   `Calendar.current`). Nejstarší relevantní hranice = `startOfYear`.
2. Projdi projekty v `~/.claude/projects`. Pro každý `*.jsonl` **přeskoč soubor,
   jehož `mtime < startOfYear`** (nemůže obsahovat letošní eventy) — hlavní
   optimalizace, aby sken nebyl drahý.
3. Ve zbylých souborech čti řádky; přeskoč ty bez `"usage"`. Pro validní
   `assistant` řádek s `usage` + `timestamp`:
   - `total = input + cache_creation + output + cache_read`
   - `cost = Pricing.cost(...)`
   - přičti `(total, cost)` do každého okna, jehož cutoff `date` splňuje
     (`date >= now-24h` → last24h; `>= now-7d` → last7d; `>= now-31d` → last31d;
     `>= startOfYear` → thisYear). Paměť O(1) — nedrží se jednotlivé eventy.
4. Nastav `computedAt = now` a vrať přes completion na main threadu.

Pozn.: full rescan (bez inkrementálních offsetů). Díky prořezání podle `mtime`
a přeskakování řádků bez `"usage"` je to dostatečně rychlé pro on-demand běh
při otevření okna. Perzistence ani offset cache se nezavádí (YAGNI).

### 3. UI — sekce SPEND (`MainWindow.swift`)

**Layout refaktor:** `buildContent()` se přepíše na **top-down kurzor** — pomocná
struktura drží běžící `y` od horního okraje a klesá po přidání každého řádku.
Tím zmizí dnešní roztroušené magic-numbers a přidání sekce je triviální. Výška
okna se zvětší, aby se sekce vešla; ostatní chování okna zůstává.

**Sekce SPEND** (umístěná pod „Second line" popupem, nad ACCOUNTS):
- Nadpis `SPEND` ve stejném stylu jako `ACCOUNTS` (10pt semibold, secondary).
- Čtyři řádky: `Last 24h`, `Last 7 days`, `Last 31 days`, `This year`.
  Vlevo popisek, vpravo hodnota `"<tokeny> · $<cena>"` — tokeny přes existující
  `shortTokens(_:)`, cena `String(format: "$%.2f", …)` (nebo `$%.0f` nad ~$100).
  Rovnocenné (stejný font/váha), zarovnané vpravo.
- Dokud `computedAt == nil`, řádky ukazují `…`.
- Pod řádky malá šedá poznámka (11pt, secondary): `Estimate from local transcripts.`

**Napojení dat:** `MainWindowController` dostane volitelný callback / vlastní
`SpendStats` instanci a cache `SpendSummary`. V `present()`:
- pokud je cache čerstvá (`computedAt` mladší než ~60 s), použij ji hned;
- jinak vykresli placeholdery a spusť `spendStats.compute { … }`, po dokončení
  aktualizuj jen labely SPEND sekce (drž reference na 4 hodnotové `NSTextField`y,
  ať se nemusí přestavovat celé okno).

## Chování / edge cases

- **Žádné transkripty / prázdno:** všechna okna `0` → zobraz `0 · $0.00`.
- **Okno otevřené během přepočtu:** placeholdery `…`, doplní se async; když
  uživatel okno zavře dřív, completion jen zahodí (guard na `window.isVisible`).
- **Reopen do 60 s:** použije se cache, žádný sken.
- **Souběh s `UsageStats`:** nezávislé; SpendStats má vlastní background queue.

## Testování

Projekt nemá test target (SPM je „rozbité", buildí se přes `./build.sh`).
Ověření tedy manuální + izolovaně:

- Pomocná funkce agregace (bucketing eventu do oken podle data) se napíše tak,
  aby šla volat čistě nad polem `(date, tokens, cost)` — ověřitelné ručně/malým
  ad-hoc harnessem, že event na hranici okna padne do správných kbelíků.
- `Pricing.cost(...)` po refaktoru dává stejné hodnoty jako dnešní inline vzorec
  (kontrola na jednom příkladu z reálného transkriptu).
- Manuální: build přes `./build.sh`, otevřít okno, ověřit že SPEND sekce ukáže
  nenulové hodnoty odpovídající zhruba dnešnímu islandu za 24h.

## Mimo rozsah (YAGNI)

- Perzistence historie / vlastní databáze spendu.
- Přesná fakturační cena z Anthropic API.
- Grafy, per-model / per-projekt rozpad, export.
- Inkrementální offset cache pro SpendStats.

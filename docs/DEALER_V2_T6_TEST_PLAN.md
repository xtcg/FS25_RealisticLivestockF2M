# Dealer v2: singleplayer test plan, ordered for the shortest total time

Status: **a plan for a build nobody has run in the game.** It re-orders the cards of
[`DEALER_V2_T6_TEST_CARDS.md`](DEALER_V2_T6_TEST_CARDS.md) (G01-G10, pass criteria unchanged; read them there) so that
the waits overlap and every save/load is used by several cards. Nothing here changes a pass criterion.

## Where the time goes

| Cost | Why | What the plan does |
|---|---|---|
| Game waiting | first shelf place appears at the first 0.25-month checkpoint (= **1 game day** at 4 days/month), then **1 place per game hour** (budget 1; shelf target = `maxDealerAnimals`). A pregnancy or a listing ageing needs game days. | Start the clock first (enable immediately), do every read-only card while it runs, buy pregnant stock early so the birth wait overlaps the rest. |
| Load / quit cycles | each costs a full game start | 3 loads in the main run instead of one per card; the destructive cards run last on copies. |
| Re-doing setup | pens, money, a cow due soon | one prepared base save; every branch starts from a copy of it. |
| Re-running after a defect | a failure early wastes the rest | gates (below) stop the run at the first failure of a card others depend on. |

Game time to real time: `real minutes = game hours x 60 / timescale`. At 120x one game hour is 30 s, one game day 12 min.
Use the highest timescale for every wait; **drop to 1x only for the 15 s quote window** (G02/G03/G07 confirm) - or confirm at once
after the quote, the window is 15 s of *real* time and a high timescale does not shorten it.

## Step 0: offline, no game (about 5 minutes, do it first)

1. `python tests/run.py` must print `4099/4099 passed` (or higher); `python3 tests/test_dealer_v2_analyzer.py` OK.
2. Build the package from the commit under test; record SHA and SHA-256. Install it once.
3. Prepare the **base save** once (reuse it for every later run). On a copy, with identity still OFF/SHADOW:
   - one player cow that is **pregnant and due within about 2 game days** (G06; the one long natural wait, so prepare it before the run: inseminate/breed it a pregnancy ago, or pick a cow already far along);
   - a pen A with **exactly 2 free places** (G02), a pen B with **exactly 1 free place** (G04a), a built pen C with 8 or more free places (G07), one pen **under construction** (G04c), a livestock trailer (G03);
   - money for about 6 animals (a few 10k) and the game days-per-month set to **4**;
   Make 3 copies of the folder: `base` (never played), `runA`, `runB`. The run uses `runA`; `runB` is for G10; `base` re-creates either.
4. Open `log.txt` in a terminal tail so each card's evidence can be cut as it happens (`tail -f`); do not wait until the end.

## Smoke run for the PR #58 review fixes (the shortest useful order)

When only the review fixes are being checked, run these and skip the rest. Each item is a card's pass criteria.
1. `runA` Load 1 steps 1-3 (G01), then step 7 (**G02** = order A; also Gate 2).
2. Step 11 (Load 2): `rlDealerV2Order <A>` unchanged, **order C** commits under a new epoch, no REQUEST_CONFLICT (**G07** steps 5-7,
   order B optional).
3. Step 12b (**G12**: OFF, a numbered animal sold, `rlIdentityActivate`, the next key is new).
4. `runB`: **G10b** then **G11** (recovery clear, the next keys are new, reload keeps READY).
Copy `log.txt` after each item; G11 and G12 need their own log for KEY-NOT-REISSUED (see the analyzer header).

## Main run (`runA`): one linear session, three loads

Times are game time at 4 days/month; the real time follows from the formula above. "||" marks a wait you fill with the next lines.

**Load 1 (identity + shelf start).** The whole point is to start the shelf clock as early as the rules allow.
1. Load `runA`. `rlIdentityStatus` -> SHADOW, READY. `rlIdentityReport`. *(G01 steps 1-2.)*
2. Decide the accept question from the report: if it lists unprovable herds, `rlIdentityActivate accept` is *your* decision (weaker guarantee); otherwise plain `rlIdentityActivate`. Skip the "play a few days in SHADOW" observation here - it only logs; the collision counter is a bonus, not a pass criterion.
3. Save (a single save serves G01 and the dealer gate). `rlIdentityStatus` -> mode ON, `generation=1`. `rlDealerV2Enable`, `rlDealerV2Status` -> `gate=true`.
   **Gate 1:** ON + READY + gate true, else stop and fix (every later card depends on it).
4. Set the highest timescale. **|| wait 1 game day for the first checkpoint, then about 1 listing per game hour.** Fill the wait with, in this order:
   - `rlIdentityDump` (**D0**, the baseline for the analyzer);
   - the player cow of G06 keeps pregnant in the background (its birth lands somewhere in these days);
   - when the first rows exist: **G09** - run `rlDealerV2List` and `rlDealerV2Detail` ten times, then `rlIdentityDump` (**D1**); live keys and money must equal D0 (it is the cheapest card; it also proves the read path works before any money moves).
5. When about 8 listings exist (`rlDealerV2Status` shows the count) pick, with `rlDealerV2List` / `Detail`:
   two animals for pen A (G02), **at least one pregnant** (G05 - the birth wait starts with this purchase), two more for the trailer (G03, one type), one more for pen C.

**Orders (all in one stretch; no loads in between).**
6. **G04 refusals first, they cost nothing and fail fast:** (a) `Pens`/`Quote` two animals into pen B -> refused, (b) a quote above your money (take a pricey listing and, if needed, spend money down), (c) the pen under construction. `rlIdentityDump` before/after: identical except the clock.
7. **G02:** `rlDealerV2Pens` -> `Quote <penA> <id1> <id2>` -> `Confirm` straight away. `rlIdentityDump` (**D2**).
   **Gate 2:** COMMITTED, both in pen A with the listed tags, money -quote. If it fails, stop: G03/G05/G07 stand on it. Run the analyzer now (`python tests/dealer_v2_analyzer.py log.txt`).
8. **G03:** the same with the trailer as `<ref>` -> `Confirm`; check weights; `rlIdentityDump` (**D3**).
9. **G07 steps 2-4 inside the same stretch:** earn or sell something (sell one animal), move one bought animal to pen C, then **Order B** (one animal into pen C). `rlIdentityDump` (**D4**).
10. **G06/G05 birth wait.** || Keep the timescale high until the player cow of G06 calves and the dealer-bought pregnant dam is close. Use the wait for: reading the doc cards you still owe results for, and writing the result table (below). G05's reload requirement is met by Load 2.

**Load 2 (G01 step 3, G07 steps 5-7, G05, G06 in one reload).**
11. **Save, quit to menu, load `runA` again** (the only deliberate reload before the destructive cards).
    - `rlIdentityStatus` -> ON, READY, a higher `generation` than before the save: **this is G01 step 3**; `rlIdentityDump` (**D5**): no RECOVERY_REQUIRED, every animal CONSUMED, no duplicate live key.
    - `rlDealerV2Enable`; `rlDealerV2Order <A>` and `<B>` -> COMMITTED, same amounts, **no debit** (money in D5 = money in D4). *(G07 step 6.)*
    - **Order C** (any 1 animal) with `rlIdentityDump` around it -> debits once. *(G07 step 7.)* Run the analyzer with `--allow-income`.
12. Highest timescale until the birth(s): **G06** (the player cow: each calf's key CONSUMED, an unborn twin's key BURNED, no repeat) and **G05** (the calf's key is the fetus key from the dump before the birth; dam and calf CONSUMED; no second calf). One `rlIdentityDump` (**D6**) after both.

12b. **G12** (OFF, one numbered animal sold, `rlIdentityActivate`, one more numbered animal; dumps M0-M3). Copy `log.txt` first: the
    reissue check must not see the reload of step 13.

**G08 last in the run (it needs a loss of the run state, so it ends the run).**
13. Save. `rlIdentityDump` (**D7**). Buy one animal (G02-style). Quit **without saving**. Load `runA` (**Load 3**). `rlIdentityStatus` shows the burned keys, the animals and money are those of D7, `rlIdentityDump` (**D8**): the burned keys are BURNED and not handed out again (buy once more and check the new key is a different one).

Totals of the main run: 3 loads, one timescale-limited wait (about 1 game day for the shelf + about 8 hours for the listings, overlapped with G09/G04/G02/G03/G07), one birth wait that overlaps all order cards.

## Destructive run (`runB`, can start at the same time as soon as a second game install/instance is possible; otherwise after the main run)

Order by effort, each from a **fresh copy** of `runB`; keep the broken files:
1. **G10b first** (replace `placeables.xml` with the previous save's): needs only one load -> expect RECOVERY_REQUIRED, old counters back in use, an error line naming the file. Nothing is regenerated or repaid.
1b. **G11** right after G10b, in the same recovery (two animals numbered during it, one sold, `rlIdentityRecoveryClear`, one more, reload).
2. **G10a** (kill the process during a save, then load): the same readout. Do it on a copy that already has one dealer order so the journal and the WAL both have something to hold.
Both need identity ON, so make `runB` from `runA` right after step 3 of the main run (state: ON, one save) - no dealer wait is needed, they do not use the shelf.

## Stop rules (save the time of a doomed run)

| Failed | Stop | Still run |
|---|---|---|
| Gate 1 (ON/READY/gate) | everything | the offline suite only |
| G09 (reading changes state) | all order cards | G01, G10 |
| Gate 2 (G02 not COMMITTED) | G03, G05, G07 | G04, G06, G08, G10 |
| Load 2 shows RECOVERY_REQUIRED | G07 (5-7), G05, G06 | G10 (it is the same family) |

Do not retry a failed order in the same run: save the evidence (`log.txt`, the dumps, the files of the savegame) and decide offline.

## Evidence kept per run

- `log.txt` copied after Load 1, after Load 2 and at the end (the log is overwritten on start).
- The dumps D0..D8 marked in the plan; the analyzer: `python tests/dealer_v2_analyzer.py log.txt` (and `--allow-income` for the income run).
- The savegame folder after step 7 and after step 13 (for a diagnosis without a new run).

## Result table (fill it in; PENDING stays PENDING)

| Card | Where in the run | Result | Evidence |
|---|---|---|---|
| G01 | Load 1 steps 1-3, Load 2 step 11 | PENDING | |
| G09 | step 4 | PENDING | |
| G04 a/b/c | step 6 | PENDING | |
| G02 | step 7 | PENDING | |
| G03 | step 8 | PENDING | |
| G07 | steps 9, 11 | PENDING | |
| G06 | step 12 | PENDING | |
| G05 | step 10-12 | PENDING | |
| G08 | step 13 | PENDING | |
| G10 a/b | destructive run | PENDING | |
| G11 | destructive run 1b | PENDING | |
| G12 | step 12b | PENDING | |

## Optional: shorter still (needs your yes, changes the test build only)

The longest remaining wait is the shelf fill at 1 place per hour. A **test-only** console switch that raises the scheduler budget
(`overrides.budget` already exists in `RLDealerRuntime`) would fill 8 listings in the first checkpoint tick instead of 8 game hours,
and a console command to set the checkpoint to 0 would remove the 1-day wait; together about 1 game day less (12 real minutes at 120x).
It also means the code path under test differs from the shipped one (the budget), so it is **not** in the plan above; say if you want it.

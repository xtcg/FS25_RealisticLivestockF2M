# Dealer v2: singleplayer test cards (T6)

Status: **written for a build that nobody has run in the game yet.** Every result below is PENDING until a
session produces the evidence listed on its card. The offline suite proves the modules; it does not prove
the installed map, the engine's save pass, or any GUI.

Run order and time-saving: [`DEALER_V2_T6_TEST_PLAN.md`](DEALER_V2_T6_TEST_PLAN.md) (3 loads, overlapped waits). The cards below stay the pass criteria.

## Before any card

1. Work on a COPY of the savegame (never the only copy). Note the code SHA of the package, its SHA-256, the map and mod list,
   the days-per-month setting (the main scenario is **4 days per month**; 1 day is the edge case) and the host farm's money.
2. The dealer has no screen yet. Everything is driven from the console (`~`), singleplayer only. Commands:
   `rlIdentityStatus`, `rlIdentityReport`, `rlIdentityActivate [accept]`, `rlIdentityMode OFF|SHADOW`, `rlIdentityRecoveryClear`,
   `rlIdentityDump`, `rlDealerV2Status`, `rlDealerV2Enable`, `rlDealerV2Disable`, `rlDealerV2List [cursor] [sort]`,
   `rlDealerV2Detail <saleId>`, `rlDealerV2Pens <saleId>...`, `rlDealerV2Quote <penRef> <saleId>...`, `rlDealerV2Confirm`,
   `rlDealerV2Order [orderId]`.
3. Evidence: copy `log.txt` after each card. `python tests/dealer_v2_analyzer.py log.txt` checks identity and money
   (needs two `rlIdentityDump` blocks around an order). INCOMPLETE is not a pass.
4. Timing at 4 days per month: one game month is 4 days; the stock check runs every 0.25 month = **1 game day**; a new shelf place
   needs one game day to appear and one hourly tick per place (budget 1 place per hour). Wait about 2 game days after enabling.
   A listing lives 0.5 / 1 / 2 months by kind = 2 / 4 / 8 game days.

## G01 first initialisation
1. Load the copy. `rlIdentityStatus` -> mode SHADOW, state READY, no ledger. Play a few game days; births and purchases only log.
   Later `rlIdentityStatus` shows `shadow observed=N collisions=C`: **C > 0 is the old defect being observed, not a failure.**
2. `rlIdentityReport` -> read the domain lines. `rlIdentityActivate` refuses when a herd has no provable history; the refusal lists
   the herds. **Decision for you:** `rlIdentityActivate accept` takes the weaker guarantee (keys of animals that exist now are protected;
   old keys of animals long gone are not).
3. Save, quit to menu, load again. Expect `rlIdentityStatus`: mode ON, checkpoint READY, `generation=1`. `rlIdentityDump` once.
PASS when: the second load shows the ledger (no RECOVERY_REQUIRED), the dump lists every animal as CONSUMED, no duplicate live key.

## G02 two animals into a pen with exactly two free places
1. `rlDealerV2Enable` (needs identity ON). Save once; `rlDealerV2Status` must say `gate=true`.
2. Wait about two game days. `rlDealerV2List` -> rows with `sale=` ids.
3. `rlIdentityDump`, note money. `rlDealerV2Pens <id1> <id2>` -> your pens, free places, verdict. Pick one with `usable=true`.
4. `rlDealerV2Quote <ref> <id1> <id2>` -> amount. Within 15 s `rlDealerV2Confirm`. Then `rlIdentityDump` again.
PASS when: ORDER COMMITTED, the two animals are in the pen with the listed ear tags, money fell by exactly the quoted total, analyzer PASS.

## G03 trailer, two animals of one type
As G02 with a livestock trailer as `<ref>`. PASS when the trailer holds both with their listed weights and nothing else changed.

## G04 refusals
a) a pen with one free place for two animals; b) more than your money; c) a pen under construction. Each: `rlDealerV2Quote` refuses or
`Confirm` answers ROLLED_BACK; no animal moves, no money moves, `rlIdentityDump` before/after identical except the clock.

## G05 pregnant dam
Buy a listing the detail shows as pregnant (`rlDealerV2Detail`). Save, reload, wait for the birth. PASS when the calf's key is the
fetus key shown by `rlIdentityDump` before the birth, the dam's key and the calf's are both CONSUMED, and no second calf appears.

## G06 ordinary birth
Let a player cow calve with identity ON. PASS when each calf has a CONSUMED ledger key, unborn twins' unused keys are BURNED, and no key repeats.

## G07 two orders, income, a move, save, reload, buy again
1. Order A (G02). 2. Sell something or earn money. 3. Move one bought animal to another pen. 4. Order B. 5. Save, quit, load.
6. `rlDealerV2Order <A>` and `<B>` -> both COMMITTED with their amounts. 7. Order C. `rlIdentityDump` around it.
PASS when A and B are answered without a debit, C debits once, the analyzer (use `--allow-income`) PASSes.
Order ids are `console-<session epoch>-<n>`: C's epoch part differs from A's and B's (a new session after the load), and no
`RLDEALERV2 ORDER ... refused: REQUEST_CONFLICT` line appears (the analyzer's ORDER-ONCE FAILs on it). After C,
`rlDealerV2Order <A>` once more: still A's amount, unchanged by C.

## G08 leave without saving
Save. Buy (G02). Quit WITHOUT saving. Load. PASS when the animals and money are as at the save, `rlIdentityStatus` shows burned keys
(`ledger` grew) and the burned keys are never handed out again (`rlIdentityDump` ledger lines BURNED).

## G09 reading changes nothing
Run `rlDealerV2List` and `rlDealerV2Detail` ten times. PASS when only the clock moved: dumps before/after show the same live keys and money.

## G10 controlled faults (on copies only)
Keep the original bad files. a) Quit during a save (kill the process) then load. b) Replace one participant file (placeables.xml) with the previous
save's. Expect RECOVERY_REQUIRED, the old counters back in use, an error line naming the file. No automatic repayment or regeneration.

## G11 numbering after `rlIdentityRecoveryClear` (PR #58 review P1; destructive run, after G10b)
Starts in RECOVERY_REQUIRED (G10b). Needs two animals numbered **during** the recovery: calves born in a player pen (a cow due within the
wait), or new animals of the old shop (they are numbered when it restocks).
1. `rlIdentityStatus` -> RECOVERY_REQUIRED. `rlIdentityDump` (**R0**).
2. Wait until two new animals X and Y exist. `rlIdentityDump` (**R1**, both live). Sell Y. `rlIdentityDump` (**R2**, Y gone).
3. `rlIdentityRecoveryClear` -> `recovery cleared; the ledger took in N live record(s) ...` (a `recovery kept: ...` line is a refusal:
   note the reason, it is not a pass). `rlIdentityStatus` -> READY, ON.
4. Wait for one more numbered animal Z in the same herd (or the same shop). `rlIdentityDump` (**R3**).
5. Save, quit, load. `rlIdentityStatus` -> READY, ON (no RECOVERY_REQUIRED). One more numbered animal, `rlIdentityDump` (**R4**).
PASS when the analyzer on this log PASSes LIVE-UNIQUE, LIVE-IN-LEDGER (R3, R4) and **KEY-NOT-REISSUED** (Y's key never comes
back); X is CONSUMED in the ledger from R3 on; Z's key is neither X's nor Y's.

## G12 numbering after OFF / SHADOW and `rlIdentityActivate` again (PR #58 review P2; main run, after G05/G06)
The ledger is ON (G01). Needs one numbered animal while OFF and one after the re-activation, in the same herd (births or shop restock).
1. `rlIdentityDump` (**M0**). `rlIdentityMode OFF`.
2. Wait for a new animal N1 (numbered by the old counter). `rlIdentityDump` (**M1**, N1 live). Sell N1. `rlIdentityDump` (**M2**).
3. `rlIdentityActivate` **without** `accept`: a herd the ledger already holds needs no new acceptance. A refusal naming such a herd is a
   FAIL; one naming a herd new since G01 is expected (then `accept`). `rlIdentityStatus` -> ON.
4. Wait for a new animal N2. `rlIdentityDump` (**M3**).
PASS when KEY-NOT-REISSUED, LIVE-UNIQUE and LIVE-IN-LEDGER (M3) PASS: N2's key is not N1's. The same with `rlIdentityMode SHADOW` in
step 1 is optional (same code path, covered offline by R8).

## Not covered by these cards
Multiplayer (the enable switch refuses it), other species, other maps/containers, any GUI. They stay PENDING in
[`DEALER_V2_STATUS.md`](DEALER_V2_STATUS.md).

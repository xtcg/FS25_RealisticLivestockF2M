# Sheep S5 game short test (single player)

Status: **not done**. The calibration lists it as UNVERIFIED until someone has played these steps and filled in the results table below. Nothing here has been tried in game yet.

## Setup

- Build from `feat/sheep-s5-nutrition`. Write the commit you tested in the results table.
- Deploy together with EconomyTuner main `9a37551` (wool and meat prices).
- Use a copy of a savegame, never the main save.
- The shipped `xml/weightProfiles.xml` keeps SHEEP `enabled="false"`. For the test only, put a copy at `modSettings/FS25_RealisticLivestockRM/weightProfiles.xml` with `<animalType name="SHEEP" enabled="true" …>`. Remove that copy afterwards.
- In the RL settings, set the nutrition mode to the real-equivalent model.
- Turn the log on. The useful console reports are `rlFeedReport`, `rlPenReport`, `rlBcReport` and `rlWeightProfiles` (check SHEEP is on).

## Steps

| # | Area | Steps | Expect |
|---|---|---|---|
| 1 | Feed supply | Put ewes and lambs in a sheep pen. Fill the trough with grass, then silage, barley and peas. | While the pen runs the mode (`rlPenReport`: active, OK), the trough takes silage, barley and peas. The pen info shows the ration. Lambs at foot eat at most 0.35 kg DM of concentrate a day (`rlFeedReport`). |
| 2 | Ewe and lambs | A ewe with twins, at least one game day. | `rlPenReport` lists each lamb's milk cap. The ewe's milk is paid by her budget and taken by her own lambs; none is stored or sold. Her BCS falls through early lactation. |
| 3 | Weaning | Let lambs pass 3 months with their ewe. Separately, move a 2-month lamb away from its ewe and give it barley. | At 3 months the lambs are off milk. The moved lamb triggers the "lamb away from its ewe" notification once. It is weaned early after about 3.5 model days on creep of 250 g or more a day, and stays weaned when moved back to its ewe. |
| 4 | Mixed pen fallback | Add a goat to a sheep pen for a few hours, then move it out. | With the goat in, the pen leaves the mode (`UNCOVERED_ANIMAL`) and the trough refuses silage and grain. Sheep take the old weight rule, with no jump in weight. Once the goat is out, the pen runs the mode again, with no double step in the hour of the change. |
| 5 | Save and load | Save while a lamb is partway through its creep days, and while one is weaned early. Load. | Weight, BCS / fat class and the weaned state are unchanged after the load. A lamb whose creep days were interrupted (a gap of hours without steps in the mode) starts its count again. |
| 6 | BCS recovery by hand | After weaning, set the ewes' pen target to FINISH. When a ewe reaches BCS 3.25, set the pen to MAINTAIN. | Under FINISH her BCS rises (offline: 2.29 to 3.25 in about 2–3 months). After MAINTAIN it stops rising. AUTO alone keeps a dry ewe at BCS 3.0. |
| 7 | Performance | A pen of about 300 sheep at a 28-day month. | No visible stutter at the hour change (offline: about 13 ms a game hour). |

## Results (fill in)

| Date | Build commit | Step | Result | Log / screenshot |
|---|---|---|---|---|
| | | | | |

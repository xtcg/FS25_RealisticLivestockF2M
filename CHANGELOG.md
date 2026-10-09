# Changelog

## Unreleased

### Added

- Body condition for cattle: every animal past 6 months carries a body reserve (0..1) that is part of its live weight. Bulls and steers show a finish score (0-100: lean, store, moderate 65-80, fat, overfat) and a slaughter verdict that weighs weight against the slaughter reference, the finish score, the slaughter age and whether the animal may be sold (a 300 kg bull at finish 72 is "still growing", not ready). Cows and heifers show a BCS (1-5) and their conception factor; every covered animal shows how well its ration covers its need, and a lactating cow her milk as a share of her full yield. These show without a monitor (condition is scored by eye) and as herd filter fields; a cattle pen's info box shows its mean BCS, thin and fat animals, bulls ready, and the last hour's ration (share eaten, energy, water). Health and the health gene keep their own meaning. Settings in xml/bodyCondition.xml; a copy in modSettings/FS25_RealisticLivestockRM/ replaces it; enabled="false" switches back to the old rules and keeps the saved conditions.
- Each hour a pen's actual consumption (trough removals during the feeding and what the meadow lost; food added by a player or a feeding robot does not count) is shared between its animals by their food request: each gets its request's share of every liter eaten, valued at the fill type's energy and the breed's grass, hay and silage traits. What it eats is measured against what an average animal of its kind, age and state requests on full feed, so an animal that eats more liters (a high-yield cow, a bigger frame) gets more energy, one that eats fewer or poorer liters less. The budget pays maintenance, pregnancy, then growth and milk (milk first for a lactating cow); a shortfall is drawn from the reserve (at most 0.08 a month), a surplus stored in it (at most 0.07 a month, up to a ceiling). The reserve stays in the weight: frame and reserve together are the live weight, and a kg laid down costs more energy than a kg drawn gives back.
- Bulls and steers on full TMR follow exactly the old growth line (every breed reaches its slaughter reference in the same month) and arrive finished, at finish score 72. Kept on past it they keep gaining but lay down more fat, so the carcass yield per kg falls (yield factor 1 from 65 to 80, 0.95 at 90, 0.88 at 100). Silage and hay take about 0.5-1.5 months longer than before to finish, grass about the same; a Highland finishes on grass.
- Cows run a lactation cycle: they draw on their reserve at the peak and rebuild it late and when dry. A Holstein or Swiss Brown on TMR with the dry period on hay calves at about BCS 3.1-3.4, bottoms at 2.5-2.8 and gives 98% of her full milk. A dry cow holds her condition on hay and fattens on TMR (to BCS 4.0 at most). A thin cow (below BCS 2.2) stops giving her reserve to milk and gives less milk instead: on silage a Holstein gives about 82% of her milk (was 80%). A high-productivity cow eats up to 25% more (1 + 0.8 x (productivity - 1)) and gives more milk, but runs thinner. Suckler breeds (Angus, Limousin, Hereford, Highland) take more from forage: a grazing herd keeps BCS 2.2-2.7 on grass, and gets fat on TMR.
- Water caps a cow's milk in the budget. A cow's milk is deposited in the same hour her budget pays for it: the store takes the covered cows out of the base deposit (which scales by the pen's food factor and slow production factor) and, after the hour's budget, deposits what each cow's budget paid, once. Straw, bedding and a full store still count, read from the pen's own production rules at full feed (no division by the food factor). An hour in which a pen has no feed ledger is the old rules for weight and milk alike. Other animals' milk, goat milk and Hof Bergmann's bull semen are deposited as before.
- Conception: both the natural and the insemination roll are multiplied by the cow's condition (1 from BCS 2.5 to 3.25, 0.65 at 2.0, 0.2 at 1.0, 0.75 at 4.0) and by how fast she is losing it (down to 0.75). At a normal BCS the roll is exactly the old one; genes, semen and offspring draws are unchanged.
- Carcass yield (meat kg at the butcher and the slaughterhouse, and the live price's slaughter floor) is multiplied by the finish score's yield factor, once, in the shared yield code. The weight part of a live price follows the same curve; the lactation and pregnancy parts do not.
- Calves under 6 months, other species and Hof Bergmann's MILKCOW keep the old rules. Every animal's condition starts at reserve 0.45 (BCS 2.8, finish 65), where the yield and price factors are 1, so an old savegame, a calf leaving the calf stage or a dealer animal changes no value by it. The state is saved with the animal and streamed with it; each hour the server sends every cattle pen's new weights, conditions and budgets to the clients (RLBodyConditionStateEvent; a client cannot send it), and a joining client takes the server's bodyCondition.xml values (RLBodyConditionConfigEvent).
- Console commands for testing (single player / server, development console): rlBcReport [animals] [pen] shows each cattle pen's last feed ledger, water and condition range (and each animal); rlBcSet <reserve|bcs|finish> <value> <all|pen:NAME|uniqueId> sets condition, moving weight with it; rlBcFastForward <hours> [pen] runs that many hourly cycles of the cattle pens at once through the real feeding, budget and milk code (ages, days and pregnancies do not advance).
- tests/test_bodycondition.lua: the budget's energy ledger and bounds, the calibration against the old growth line for every bull and against the milk yield for both dairy breeds, 1/3/7 days per period, the feed ledger, conception, the carcass factor, save and stream round trips and the milk deposit.
## Unreleased (xtcg fork, Hof Bergmann)

### Fixed

- Animals bought or moved into a pen lost health in their first hour although the trough was full: a pen's food, water, straw, manure, milk and pallet liters per hour were only set after each hour's feeding, for the next hour, so the first feeding after a herd change used the old herd. A pen empty the hour before asked for no food, the engine then returns food factor 0, and every new animal lost a full hour's health (decreasePerHour x its health gene: a cow 100 -> 68, a calf moved to a rearing box 100 -> 69), while the pen it left kept eating for it for an hour; into an occupied pen the newcomers diluted everyone's share for that hour. The server now sets a pen's totals again whenever its animals change (bought, moved, sold, born, died), from each animal's current per-hour input and output; the hourly totals are unchanged otherwise. Not a base-game behaviour: the base game also sets them on every herd change.
- Body condition texts no longer overlap or get cut off. A cattle pen's info box (e.g. the Bull barn) drew its whole summary as one value next to a long title, so key and value ran into each other in English; it now shows one short figure per row: Avg. BCS and Cows thin / fat (pens with cows), Bulls ready (3 / 5) and Bulls overfat (pens with bulls), and Feed eaten, Ration energy and Water cover from the last hour. In the RL menu's animal stats (upper case, label up to 145 px, value up to 200 px) "Ration covers need" and the slaughter verdict with its weights were cut off: the verdict is now short (Ready, Needs finishing, Still growing, Growing, Overfat, past best, Too young, Cannot be sold) and the weight against the slaughter reference is its own row (Finish weight 612 / 650 kg); the labels are Condition, Ration cover, Milk output and Fertility (BCS). The stat grid had 10 cells, so a pregnant lactating cow (12 rows) lost her last two; it now has 14 and shrinks to the rows in use.
- Why an animal cannot reproduce is short enough for the same grid: "Under 12 months", "Recovers in 3 months", "No suitable male", "Health < 75 %" (was "Recovering from last birth (< 2 months)", "No suitable male animal (< 0)"). The minimum health was printed with %d from its 0..1 factor, so it read "< 0 %"; it is now the percentage. The in-world animal box reads "No (recovering)" and "No (no suitable male)", and German "Zuchtfähig" instead of "Kann reproduzieren".
- The Chinese translation is complete: the RL menu (manage, move, transfer, sell, buy, insemination, herdsman, messages, settings, filters), body condition, the newer settings and messages, and the dialogs were still in English (345 texts). German has the new body condition texts too; the other languages show them in English.
- Chinese texts drew characters as blanks: the game's font holds only the characters its own texts use, so the gender row of a cow read "性" (雌性 without 雌) and the father in the pedigree lost 父. 149 Chinese texts are reworded within the font (checked against every character in the base game's texts, tests/fs25_font_glyphs.txt): 公 / 母 for sex, 母畜 / 公畜 for the parents, 妊娠, 产奶期, 去势, 感染 and 护理 for disease and treatment, 检测器 for the monitor, 精液罐 for the dewar, 处置 for cull, 加工 for the butcher, 小牛 / 小羊 / 幼仔 for the young, and the base game's horse colour and sheep breed names. Disease names are descriptive (乳房感染, 口足感染 (FMD), 牛呼吸道感染 (BRD), ...).
- tests/test_ui_text.lua: every translation file has the English keys once each with the same format placeholders, the Chinese file has no English text left and only characters the game font has, the body condition texts fit their cells, and every menu frame has a cell for each stat row.

- Hof Bergmann's calf igloos took animals before they were built: a calf could be bought or moved into an igloo still in SETUP (1000 CALFIGLU not delivered), because neither the engine nor the map checks construction when an animal comes in. A husbandry with a construction state machine now takes animals only in the states its bridge names (husbandryProfiles.xml <construction readyStates>): the five igloos and the buildable cow pasture from DONE, the farm cow barn in all its states (its STEP1/STEP2 only add the milk tank and robot). The state is read by name and live on every check, so a pen opens the moment its construction finishes. Buy and move destination lists leave an unbuilt pen out; the server refuses a buy or move into it before any animal, stock or money changes, with its own reply (PEN_NOT_BUILT, code 8: "This pen is not built yet") instead of "not supported", and so do the herdsman's buy and move (skip reason pen-not-built; no buy is planned into it). Buy and move replies are now sent in 4 bits instead of 3 (the base game's codes fill 0-7). A building no bridge names takes animals only in its final construction state, with no outstanding material inputs. Animals already in an unbuilt pen stay and can be moved out; they are logged at load and each day (INVALID_RESIDENT_UNBUILT, with health, weight, trough and the missing material), a calf born there as RESIDENT_BORN_UNBUILT, and any other new animal as ADMITTED_WHILE_UNBUILT. Construction state changes are logged (CONSTRUCTION_STATE: LOAD, PLACED, CHANGE with the previous state, opened/closed), and PROFILE_APPLIED, PEN_REPORT, the admission records and BUY_RESULT carry the construction state.
- Hof Bergmann pens refused grown cattle: buying a 12-month-or-older bull for the Bull barn, or a cow for the Cow barn (farm), failed with "already belongs to the next age stage (from 12 months)" although the move screen offered the pen. A pen rule with a minimum age and no maximum left the map filter's maximum empty, which Hof Bergmann's filter reads as "until the next visual stage" (12 months for cattle). The rule now writes an open maximum (2147483647, no limit) into the map filter, so pens with only a minimum (bull barn, dairy barn, farm 2 barn) take animals of any age above it. For a profiled pen the pen check also runs the map filter's own test on the fields it ends up with, so the move and buy screens offer exactly the pens the server's buy then accepts. Pens without a profile keep the map's own limits.
- Selling live animals: the server now prices the sale itself from the animals in the pen or trailer (each animal's sell price, minus the transport fee from a pen, none from a trailer at the dealer) and pays that. The price the client sends is only compared for the log. Before, it paid whatever price the client sent, even when an animal in the request was no longer there: a request for one missing animal at 1,234 paid 1,234 and removed nothing. A request with a missing, repeated, unsellable or sick animal, no animals, a pen or trailer the seller's farm does not own, or an animal the server cannot price is now refused whole, with nothing removed or paid; repeating a sale that went through pays nothing the second time. If removing the animals fails part way, only the animals that left are paid, the sale is reported as failed, and the rest stay unsold (not a rollback: animals already removed stay removed). Whether an animal left is checked against the pen's own animal list, not looked up by id, which after a failed removal could find a different animal. Every request now gets a reply, including when pricing an animal throws, so the client no longer waits for its timeout. Sale prices, fees and yields are unchanged.
- Herdsman automatic sales: the server now sells directly and reports what it actually sold, instead of sending an AI sale event that paid the planned amount. Receiving or running that event (from a client, from the server or locally) no longer removes animals or pays anything; it only logs. Before, it paid the planned price even for animals no longer in the pen. The plan now freezes the farm it was made for and each animal's identity; at execute the server checks that the pen still belongs to that farm, that every animal is in the pen once, sellable and not sick, and prices each animal again (sell price plus transport, as the herdsman always paid, unlike the player's sale). Any problem refuses the whole batch with nothing removed or paid; a batch also waits for another day when other removals are already queued in the pen. If removal fails part way, each animal that left is paid its own price and the rest are taken off the removal queue. The herdsman's messages show the animals and money actually sold. When the pen list cannot be read after removal or the payment throws, the sale is logged as failed with the stage, never announced, retried or refunded (recovery is a later task). The wage is unchanged, except that it is no longer charged when the pen changed owner since the plan. Mark mode is unchanged.
- Hof Bergmann 1.5 Beta2's public slaughterhouse gave 1000 kg of beef per typical animal again, for the map's 100 fee. Beta2 maps its MILKCOW type (the insemination system's placeholder cow) to BEEF next to COW, and a fill type taken by two animal types was left alone, so the cattle recipe was no longer aligned (the log showed 5 recipes, no cows_processing). Only animal types with a meat per head in xml/carcassYield.xml now count, so BEEF is COW's again on Beta1 and Beta2.

### Changed

- The dealer sells for a purpose (xml/dealerStock.xml, replacing breedTraits.xml maleMaxSaleAgeMonth / femaleMaxSaleAgeMonth and eliteSaleGenetics). Each animal is generated as a weaned calf, a replacement heifer, a heifer ready to breed or in calf, a first-calver or young cow, a store bull or a young sire (and young-stock purposes for pigs, sheep and goats, chickens, ducks, geese, rabbits and horses), at an age inside that purpose's range, its sex's absolute cap (cows under 48 months, bulls under 36, Highland and Water Buffalo bulls under 42), the type's maxBuyAge and the buyable visual stages. Ages lean to the middle of the range. Good genetics are no longer an exemption: before, an elite animal could be offered at any age up to 72 months. Purposes are drawn by weight among those a subtype can be offered for (cows: weaned 15, replacement 35, ready to breed 20, in calf 10, first-calver 8, young cow 2; bulls: weaned 20, store 55, sire 10). Unweaned calves are off. A weaned calf is past the calf rearing weaning month. A breed is drawn once for each sex it has, then its sex (half female by default), so map aliases do not make a breed more likely and a bulls-only subtype keeps its old share.
- A dealer animal's breeding history fits its purpose: no replacement heifer is pregnant or has calved, an in-calf heifer conceived at the breeding age or later and is 10-70% through gestation (it was always just conceived, and 1% of dealer pregnancies lasted 2 months through a precedence bug), a first-calver or young cow calved no earlier than the breeding age plus a gestation, and one pregnant again (30%) conceived at least 3 months after calving. Only Holstein and Swiss Brown are offered ready to breed (at least 55% of their own target weight); beef breeds and buffalo need a weight of their own first. A draw that cannot be made consistent is tried again up to 8 times, then the place stays empty until the next restock. The reasons are in the hourly dealer debug summary.
- A listing that outgrows its purpose on the shelf (past its last month, or past 75% of its gestation) is withdrawn in the next hour, however recently it was listed. The purpose is saved with the listing (sale#purpose). A listing from an older save takes the first purpose it qualifies for, or is withdrawn. Types and subtypes the file does not cover keep the old rules (any buyable age up to maxBuyAge) and are logged once each: Hof Bergmann's alpacas, quails, wild ducks, cats and the bull stable bull. A purpose with weight 0 is off like enabled="false", and its listings are withdrawn. Dealer weight is unchanged (LEGACY_WEIGHT). Console: rlDealerCatalog [animalType] logs each subtype's purposes with the ages it can be offered at, why the others cannot be offered, and the pool by purpose (RLDEALER). The ages and shares are first game values for review.
- Hof Bergmann calf housing (mod_support/FS25_HofBergmann/v1.5/husbandryProfiles.xml): the single calf igloos take calves of 0-1 months (from 2 months a calf moves to a group pen); the calf rearing boxes A/B become group pens for heifers, bull calves and steers of 0-5 months (3 each), so every 2-5-month calf has a pen on the home farm; the farm 2 barn takes weaned calves from 3 months instead of 6; the dairy and bull barns still take animals from 6 months. Animals already in a pen stay when they outgrow it: on loading they are logged (OVERAGE_RESIDENT, with the pens that would take them), and when one crosses the limit its pen gets a message naming those pens. Nothing is moved, sold or removed, and births are never blocked.
- Calf rearing (xml/calfRearing.xml), in the igloos and rearing boxes only: each hour a calf can take at most part of its food request from milk and part from solid feed, by age relative to weaning at 3 months (newborn milk 100% / solids 10%, 2 months 70% / 60%, 3 months 35% / 90%, from 4 months solids only). The trough is drawn down through the engine's own consumption within these limits, and what the pen ate is shared by each calf's limits, so a weaned calf drinks no milk next to a younger one and a calf on milk alone after weaning, or on solid feed alone before it, is underfed and its health and growth show it. Health and growth use the calf's own share; an older animal still in a rearing pen is budgeted on its own share. Calves with their mothers in a barn or on pasture keep the old rules. weaningMonth may be set per breed; a copy in modSettings replaces the file, enabled="false" switches it off.
- One-line JSON records in the log (RLPEN ...): each profiled pen's rule, source file, map filter fields before and after and what its trough and water take (PROFILE_APPLIED, REARING_FEED_MISSING), every buy, move, herdsman and herdsman-move admission with both the pen rules' and the map filter's verdict (BUY_CHECK, MOVE_CHECK, AI_MOVE_CHECK, HERDSMAN_CHECK) and each buy's money before and after (BUY_RESULT), outgrown residents (OVERAGE_RESIDENT), each rearing pen's daily milk and solid feed per calf (CALF_FEED_DAY) and feeding stage changes (FEED_STAGE). Console: rlPenReport [pen].
- The cattle fine-cutting fee is 0.37 per kg instead of 1.05 (xml/carcassYield.xml, COW processingFeePerKg), so contract slaughter of a typical 270 kg animal costs 100 + 0.37 x 270 = 199.9 per batch on HARD (was 383.5), x1.8 on NORMAL and x3 on EASY.
- Bull live-price curves (sell and buy, cows unchanged) are calibrated at an annual mean beef price of 8.4 per kg (best selling point) instead of 9.44, with the new fee, so slaughtering a finished bull by contract still earns about 12% over selling it live over the year: every bull curve x0.95511 (the ratio of a typical animal's contract net, (8.4 - 100/270 - 0.37) / (9.44 - 100/270 - 1.05)). Finished bulls at 18 months sell for Holstein 1,954, Swiss Brown 1,767, Hereford 1,791, Angus 1,928, Limousin 2,123, Highland 1,355, Water Buffalo 1,323.
### Changed

- The dealer no longer offers animals heavier than their own target weight. Stock without a weight of its own (the dealer's, a new game's herds) is on the full-feed growth line +/-15% but capped at the animal's target, so a grown animal is at its mature weight instead of up to 15% over it (RLBreedTraits.getNewAnimalWeight).
- The dealer sells young stock. Each animal type and sex has a maximum sale age (xml/breedTraits.xml maleMaxSaleAgeMonth / femaleMaxSaleAgeMonth): bulls 24 months (Highland and Water Buffalo 30), cows 48, pigs 12, rams and bucks 18, ewes and does 30, poultry 12, geese 14, rabbits 8 / 12; horses keep their own range. An animal drawn older is offered only when its genetics are elite (mean of its genes at least 1.45, about the best 11%, root eliteSaleGenetics); any other is drawn again within the limit. Bulls past 24 months fall from about 10% of the dealer's bulls to about 1%, cows past 4 years from about 5% to 0.5%, and all of them are elite.

## 1.4.0.1-dev.7 (xtcg fork, Hof Bergmann)

### Changed

- Beef now follows a fixed chain: a 600 kg standard animal x 0.60 to the carcass x 0.75 to what the map sells = 270 kg of meat per typical animal (was 450). It is set in xml/carcassYield.xml on the COW type as anchorWeight 600, dressingRate 0.60 and saleableRate 0.75; pigs and sheep keep their meatPerHead (75 and 50). The farm butcher and the public slaughterhouse both give 270 kg for a typical animal, and the yield formula, breed factors and gene swing are unchanged, so an Angus bull at 600 kg gives 286 kg, a Limousin at 702 kg 298 kg, a Water Buffalo at 450 kg 236 kg. The live-price floor at slaughter value follows the lower meat (0.85 x meat kg x price), so commodity prices need raising to keep it where it was.
- The farm butcher is credited meatPerHead / (its recipe's meat per unit) units for a typical animal instead of the map's fixed unitsPerAnimal (750 units x 0.6 = 450 kg for a cow), so its meat per animal is the same as the slaughterhouse's whatever the map ships. Pigs and sheep come out as before.
- Live prices no longer read the pens' target weights and growth lines. Animal:getSellPrice measures weight against a reference line of its own (priceTargetWeight and priceMatureAgeMonth per cattle subtype in xml/breedTraits.xml, the values the prices were calibrated with), and puts an animal's weight on it as its share of the full-feed growth line. A dealer's animal is priced exactly as before the target weights were set to real ones (tests/test_priceline.lua: 0.00% difference over ages, genes and metabolism). Only the slaughter floor moves, with the meat kg; at a finishing-age dealer bull it is 0.75-0.78 of what it was, so raising beef prices by about 1.3 restores it.
- Slaughtering cattle by contract now costs a fine-cutting and packing fee of 1.05 per kg of meat on top of the slaughterhouse's own fee (100 per typical animal). It is added to the contract slaughterhouse's fee per batch at load (xml/carcassYield.xml, COW processingFeePerKg 1.05), so it goes through the same order and fee budget; the map is not edited. A typical 270 kg animal costs 383.5 per batch in all.
- The live-price floor for cattle is now what slaughtering the animal by contract earns, less a margin: (meat kg x best current beef price - 100 x typical animals - 1.05 x meat kg) / 1.12, and 0.82 of that from 30 months. It follows the beef price through the seasons and leaves 12% for slaughtering by contract over selling live (slaughterMargin 0.12, cullFloorFactor 0.82). Pigs and sheep keep meat x price x slaughterShare.
- Bull live-price curves (sell and buy, cows unchanged) are set so that at one annual mean beef price of 9.44 per kg (best selling point) slaughtering a finished bull by contract earns 12% over selling it live, for every breed. Against the dev.6 curves: Holstein x0.998, Swiss Brown x1.000, Angus x0.939, Limousin x0.907, Hereford x0.962, Highland x0.915, Water Buffalo x0.924. Finished bulls: Holstein 1,854, Swiss Brown 1,911, Angus 2,050, Limousin 2,132, Hereford 1,909, Highland 1,847, Water Buffalo 1,692.
- A bull's live price follows the beef market through the seasons: curve price x (1 + 0.6 x (net revenue of a typical animal at the current best beef price / the same at the annual mean price - 1)), kept between 0.5 and 1.5. The annual mean is read from the map (best station's price x the mean of BEEFMEAT's 12 seasonal factors x difficulty), not configured. With Hof Bergmann's factors (0.81-1.21) slaughtering by contract pays about 0% in the cheapest month, +9% to +16% in ordinary months, +22% at the peak and +12% over the year (carcassYield COW marketPassThrough 0.6). Male animals only; cows are priced by their milk.
- The cattle live-price floor is now an arbitrage cap: (net revenue of the animal) / 1.25, so slaughtering by contract never pays more than 25% over selling live, even under great demand or for a heavy, high-quality bull (maxSlaughterMargin 0.25, was slaughterMargin 0.12).
- Animals that appear with no weight of their own, such as the dealer's stock and a new game's herds, are now on the growth line of one raised on full feed (the same monthly gain as the pen, from birth weight to their own target). Before, they followed the expected-weight line to the target at the mature age, so a 19.5-month Angus bull at the dealer weighed about 400 kg where one raised in the pen weighs 600. Bulls of finishing age now arrive within 1% of their slaughter reference.
- Cattle target weights set from real mature weights (upper-middle of breed-society and extension figures), cows / bulls in kg: Holstein 730 / 1100, Swiss Brown 670 / 1000, Angus 610 / 1000, Limousin 780 / 1200, Hereford 660 / 950, Highland 500 / 780, Water Buffalo (river type) 590 / 720. Before: 680 / 1000, 650 / 900, 650 / 850, 650 / 1000, 600 / 850, 500 / 750, 550 / 900. Angus was the low one: its bull was only 1.31 x its cow.
- Cattle slaughter references (target weight x male maturity) now sit at real finishing weights, about 55-62% of a mature bull: Holstein 649 kg (maturity 0.59), Limousin 702 (0.585), Angus 601 (0.60), Hereford 571 (0.60), Swiss Brown 620 (0.62), Water Buffalo 450 (0.625), Highland 480 (0.615). They were 680 / 750 / 663 / 646 / 666 / 648 / 585 kg. Finishing ages are unchanged (17-25 months) and matureAgeMonth was solved again for each, so bulls still reach the reference at those ages. A bull yields the same beef per head at its reference; meat per kg of live weight is higher for the lighter ones (size factor 0.91-1.02 of typical instead of about 1).
- Feed to finish a bull stays within 5% of before (5,500-6,300 per head), on the breeds' own feed traits: the per-breed bull feed overrides are gone. tests/test_economics.lua now compares cattle by feed per finished bull instead of per kg gain, because per-kg feed depends on the finishing weight (Water Buffalo and Highland finish lighter, so more feed per kg gain).
- A cull cow's reference follows her new target, so cull Holstein cows now reach their reference at about 621 kg (was 578).
- Livestock prices follow the economic difficulty, like the game's own meat and milk. HARD is the calibration level (x1, unchanged); on NORMAL every livestock price is x1.8 and on EASY x3: live animals (and so the dealer's buy price, which is made from them), overcrowding and disposal sales, semen straws and dewars, and the contract slaughter fees (the map's fee and the cutting fee per kg; re-applied when the difficulty is changed in game). Meat, milk, eggs and wool already carry the game's multiplier. So every margin is the same on every difficulty: slaughtering by contract earns about 12% over the year, and a finished animal is worth the same in meat on EASY as on HARD relative to its live price. Before, on EASY the meat floor lifted finished animals far above their curve (x3 meat, x1 animals) while young stock stayed at HARD prices. Crops, feed and other costs keep the game's own rules.

## 1.4.0.1-dev.6 (xtcg fork, Hof Bergmann)

### Changed

- Recalibrated cattle, pig and sheep/goat live-market prices against the realistic body weights and finishing ages. Young finished cattle now sell around £2,000-£2,700 by breed instead of being undervalued by the old curves; six-month finishing pigs are £170-£240 rather than £375-£525; six-month lambs are £130-£220. Older breeding stock stays higher.
- Semen is priced by the sire's breeding index instead of the product of all five genes, which made an ordinary sire's straws almost worthless (every gene at 0.67 left 13% of an average sire's price) and an elite one's up to 16 times it. The index is a weighted mean of the genes a breed is kept for: dairy breeds (Holstein, Swiss Brown, Water Buffalo, goats) milk 40%, fertility 20%, health 20%, meat and feed efficiency 10% each; other breeds meat 35%, feed efficiency 25%, fertility 20%, health and milk 10% each. Price follows the index cubed, so a sire 25% above average costs about twice as much. The dealer's straws cost about what they did on average (about 18).
- Your own semen now sells at about 70% of what the dealer charges for the same genetics, like a private sale after commission. It is priced like an average AI stud's semen (price factor 1.55 instead of 1), and the sale share rose from 60% to 70%. Bought semen still resells at 70% of its price. 133 straws from an ordinary bull (genes 0.67, conception 50%) now fetch about 100 instead of 10; from an average bull about 335.
- Live animals are now worth at least what a slaughterhouse would pay for their meat. That value is the meat the animal gives at the farm butcher, at the best current price for it at a selling point, times 0.85: the other 15% is what you earn by slaughtering it yourself. From 30 months for cattle and 12 months for pigs and sheep, old cows and bulls, sows, boars and mutton sell as processing meat at 0.70. So dealer prices for finished and cull animals follow the meat price through the seasons, and buying one to slaughter it leaves only a thin margin. Breeding stock and young animals keep their age price when it is higher. The floor needs the meat fill types (Hof Bergmann); on maps without them nothing changes. Set in xml/carcassYield.xml (slaughterShare, cullShare, cullAgeMonth, slaughterMinAgeMonth, meatFillType).
- The budget dealer's markup went up from 1% to 5%.

### Fixed

- A light animal counted as at least half a typical one at the butcher and the slaughterhouse (minFinishFactor 0.5), so a 3-month 120 kg calf gave 222 kg of beef. Meat now follows weight all the way down (minFinishFactor 0): that calf gives 103 kg, a 6-month 220 kg one 173 kg. Animals near slaughter weight are unchanged.
- Hof Bergmann's public slaughterhouse gave far more meat per animal than the farm butcher: 1000 kg of beef per typical cow against 450, 500 kg of pork per pig against 75, 400 kg of sheep meat per sheep against 50. Buying animals to slaughter them there made money for nothing. Its recipes are now rescaled at load to the butcher's meat per animal (the new meatPerHead in xml/carcassYield.xml), so both give the same meat and the slaughterhouse only saves time and work. Fees stay per animal. Horses keep the slaughterhouse's own recipe, as the butcher takes none.

## 1.4.0.1-dev.5 (xtcg fork, Hof Bergmann)

### Fixed

- Selling a dewar with K did nothing once the player had been in a vehicle: the sell action was re-registered for the vehicle and the on-foot one was never switched on.
- The buy and move screens listed pens whose rules take none of the selected animals, such as a calf igloo for cattle over 5 months. A pen is now listed only when it takes at least one of them.
- Holsteins delivered to Hof Bergmann's insemination system were scaled by carcass yield like meat, so a light cow counted as less than one and the system made fewer milk cows than it was given. It now counts them by head.

## 1.4.0.1-dev.4 (xtcg fork, Hof Bergmann)

### Added

- Added collecting and selling semen from your own sires.
- Added pen rules for Hof Bergmann's cattle buildings, set in mod_support/FS25_HofBergmann/v1.5/husbandryProfiles.xml:
  - Calf igloos take all calves up to 5 months.
  - Calf rearing boxes take male and steer calves up to 5 months.
  - Bull barns take intact bulls of every breed from 6 months.
  - The farm cow barn takes Holstein and Swiss Brown cows from 6 months.
  - The cow barn with pasture takes cows, steers and bulls under 12 months, from 6 months.
  - The pastures take the same animals, calves included.
- Added xml/carcassYield.xml for the carcass yield settings. A copy in modSettings/FS25_RealisticLivestockRM/ replaces it.
- Added xml/breedTraits.xml: per-breed feed, growth and forage traits. A copy in modSettings/FS25_RealisticLivestockRM/ replaces it.
  - Feed: Highland 0.80, Hereford and Water Buffalo 0.90, Limousin 0.95, Holstein 1.10; Berkshire 1.08, Black Pied 0.90; Black Welsh 0.85 up to Swiss Mountain 1.10; goats 0.85.
  - Growth: Limousin 1.08, Hereford 1.02, Water Buffalo 0.96, Holstein 0.95, Highland 0.90; Landrace pigs 1.05; Steinschaf and Swiss Mountain 1.05, Black Welsh 0.90; goats 0.95.
  - Forage: Highland grows as if grass were 25% richer (Hereford and Water Buffalo 15%, goats 15%); Holstein does worse on grass and 10% better on silage and TMR.

### Changed

- Butcher and slaughterhouse deliveries scale with the animal: its frame (its own target weight x a slaughter maturity for its breed and sex, against 650 kg for cattle, 120 kg pigs, 50 kg sheep, 32 kg goats), how finished it is against that, its breed's carcass factor (Angus and Limousin 1.06, Holstein 0.94, Berkshire 1.08) and its meat gene.
- New target weights (cow / bull): Holstein 680 / 1,000 kg, Swiss Brown 650 / 900, Hereford 600 / 850, Angus 650 / 850, Limousin 650 / 1,000, Highland 500 / 750, Water Buffalo 550 / 900. Pigs are grown breeding weights: Berkshire 220 / 280, Landrace 240 / 300, Black Pied 180 / 250. Sheep: Black Welsh 45 / 62, Landrace 55 / 75, Steinschaf 80 / 95, Swiss Mountain 75 / 100; goats 60 / 75. Animals in a save move to the new targets; one now above it slims down over a few days.
- Black Pied finishing pigs are slaughtered at about 120 kg like the other breeds (slaughter maturity 0.67 sows, 0.48 boars).
- Growth now needs better feed for full speed: min(food factor x 1.10, 1) instead of x 1.25, so silage no longer grows as fast as TMR (grass 44%, hay 72%, silage 88%, TMR 100%).
- Milk at peak by breed: Holstein 378 (was 330), to keep its milk against the feed of its bigger frame; Swiss Brown 320 (was 255), about 85% of Holstein; Hereford 80 (265), Angus 70 (160), Limousin 60 (140), Highland 50 (160). Beef cows now give the milk left over after the calf, not a dairy cow's. Water Buffalo and goats are unchanged. Hof Bergmann's milk-can curves (v1.4 and v1.5) match.
- Daily food follows body condition: x (weight / expected weight for its age) ^ 0.35, so a heavy animal eats more than a light one of the same breed and age.
- A delivery that does not fit the facility's room or the farm's fee budget is refused whole and stays in the trailer.
- Meat animals reach slaughter weight at realistic ages on full feed (TMR for cattle): Holstein bulls 17 months, Limousin 18, Angus and Hereford 19.5, Swiss Brown 20, Water Buffalo 23, Highland 25; Landrace pigs 5.5, Black Pied 6, Berkshire 6.5; sheep 5 to 5.5. The bigger target weights had made them grow far too fast. Set by the new matureAgeMonth trait in xml/breedTraits.xml, the time scale of growth: a male with growth 1 on full feed reaches his target weight at that age, and breed growth and femaleGrowth still change the actual rate. Cows and ewes keep the old time scale.
- Gilts grow at 95% of a boar's rate (new femaleGrowth trait, was 60% like all females), so finishing gilts are ready with the boars. Cattle and sheep females stay at 60%.
- Food curves rescaled so feed per kg gained keeps the breed order: against Angus, Limousin 0.92, Hereford 0.96, Swiss Brown 1.00, Holstein and Water Buffalo 1.05, Highland 1.15; against Black Pied pigs, Landrace 0.90, Berkshire 1.15; against Landrace sheep, Black Welsh 0.93, Steinschaf 1.05, Swiss Mountain 1.09.
- Cows' food follows the change in their frame, (new target − birth weight) / (old − birth weight) ^ 0.75: Holstein x1.14, Water Buffalo x1.23, Limousin x1.03, Angus x0.94, Hereford x0.91, Highland x0.74, Swiss Brown unchanged. Milk is under "Milk by breed" above.
- Hof Bergmann's bull stable semen follows the dewar collection age curve: half at 12 months, full from 18, falling from 70% of the fertility cutoff age (132 months x fertility) toward 30% just before it, none from the cutoff on (was full from 24 to 54 months, then down to none at 168).

### Fixed

- Fixed the Hof Bergmann public slaughterhouse refusing every animal, and the delivering farm in multiplayer.
- Fixed Hof Bergmann's bull stable semen.
- Fixed Hof Bergmann's age limits on cattle buildings being skipped for RLRM moves.
- Fixed Hof Bergmann's milk-can cattle buildings (constructible cow pasture, cowPasture01, cowHusbandryFarm02) filling cans from dry cows and cows that never calved. Cans now follow the same lactation curve as tank milk.
- Fixed diseases scaling Hof Bergmann's cow and buffalo milk cans by their pallets modifier instead of the milk one: a cow with foot and mouth gave 90% in cans but 35% in a tank, and CVM's milk bonus never reached cans.

## 1.4.0.0:

### Heads up before you update

- Every disease infection, immunity, part-way treatment and CVM carrier in your save is cleared on first load - the new disease records cannot read the old ones. Your herd starts out disease-free and CVM-free.
- The Diseases setting becomes a difficulty level: an existing save lands on Normal, or Off if diseases were off. The Disease Chance setting is gone.
- A sick animal that shows symptoms can no longer be sold or taken to a butcher, by you or by the herdsman. A herdsman sell rule for animals with any disease now sells none - switch it off or change its filter.
- Foot and mouth treatment is now a one-month course like every other disease, instead of three months.

### Added

- Added avian flu (HPAI) for chickens, BRD for cattle and pulpy kidney for sheep and goats - HPAI cannot be treated, so cull a bird that shows it straight away to stop it spreading through the flock.
- Added colic, the first horse disease: a horse can fall ill with it on its own (it never spreads), grows more slowly if it is still young, and can die of it; a $500 treatment course cures it about half the time.
- Added a hidden phase on Hard and Very hard: a newly infected animal of most diseases shows nothing until its symptoms appear, and on every level the "Contracted" message now arrives on the day symptoms show; an animal still in the hidden phase already spreads its disease.
- Added illness effects on growth and breeding - most illnesses slow weight gain while an animal shows symptoms, and mastitis and foot and mouth also lower its chance of conceiving.
- Added a Cull button to the Diseases dialog for an animal showing symptoms: it removes the animal from your herd for good and pays 33% of its current sale price, or nothing for a chicken.
- Added Choose Diseases to the RL Menu settings: switch individual diseases off so no new cases of them start; animals that already have one keep it until it runs its course.
- Added a message when a treatment course ends without curing the animal.
- Added a credit to Renfordt's Enhanced Livestock: changes to the disease system are inspired by it, with some parts converted directly from it.

### Changed

- Rebuilt the disease system to run on the daily tick instead of once a month - catching, spreading, treatment and recovery all move day by day, and each disease's chance of striking is a monthly rate by age, so longer months no longer raise it.
- Turned the Diseases setting into a difficulty choice - Off, Easy, Normal, Hard or Very hard: on Easy and Normal, the default, diseases are rare or strike now and then and show symptoms at once, while on Hard and Very hard they strike more often, spread faster and most take a while to show.
- Changed natural recovery so an untreated animal that survives stays sick for at least its illness's minimum length and then recovers on a daily chance - some animals now stay sick longer than others.
- Changed every treatable disease to a one-month treatment course, charged day by day while it runs - foot and mouth drops from three months to one.
- Changed illness effects on production - less milk, goat milk, eggs, wool and manure, and PED raises liquid manure - to apply in full while an animal shows symptoms and about half as strongly while it is still in the hidden phase.
- Changed the lower sale price for a sick animal to apply only while it shows symptoms - a recovered animal or a CVM carrier now sells at full price.
- Stopped sick animals being sold or taken to a butcher while they show symptoms - by you or by the herdsman. A herdsman sell rule for animals with any disease now sells none, and in mark mode marks none; a herdsman move to a butcher leaves sick animals in the pen and tells you how many it skipped.
- Renamed Avian Flu to Avian Flu (LPAI) in every language, to tell it apart from the new HPAI.

### Removed

- Removed the Disease Chance setting - the difficulty level replaces it.

### Fixed

- Fixed saving while a horse is out of its pen removing vehicles from the save - one per horse out, taken from the start of the vehicle list and sometimes the horse itself.
- Fixed January and February messages appearing below the previous year's messages in the Messages tab; pregnancy due dates, birthdays and the feed forecast now use the right year in those months too.
- Fixed one bad entry in the disease definition file silently dropping every disease defined after it - an authoring mistake now warns and skips just the offending entry.

### Documentation

- Rewrote the disease guide to cover all nine diseases, the hidden phase and the difficulty levels.
- Corrected the settings reference: disease messages are not collected into daily summaries, though a death from disease still counts in the day's deaths summary.

## 1.3.2.1:

- Fixed newborn rabbits on the Witcombe map never gaining health, so many of them died at their first day change - rabbits of every age now eat and drink the amounts the Witcombe support sets.
- Corrected the disease guide's spread ratings - Foot & Mouth is the one disease that sustains an outbreak on its own, while PED and avian flu outbreaks usually burn out.
- Documented in the pack-creation guide which curves accept decimal values - food, water and straw do, every other curve reads whole numbers only.
- Enabled animal packs to set decimal food, water and straw rates, such as 0.2 - they were previously cut down to whole numbers.

## 1.3.2.0:

### Heads up before you update

- Treating a disease now costs money. Any animal already part-way through a course starts charging on the next month - Foot & Mouth bills $250 a month across its three months, mastitis $200 and PED $150.
- The old per-pen herdsman's leftover settings are cleared out of your save the first time you save after updating. It has not run since v1.3.0.0 and the Herdsman tab in RL Menu replaces it.
- The custom Mark Animal and Castrate Animal keybindings are gone, and any custom keys you had set for them are ignored.
- An animal already stuck showing "Being treated" after being cured keeps that label until its immunity expires; there is no repair pass.
- For mod authors: getAIManager on a Realistic Livestock animal pen is removed with no replacement.

### Diseases

- Changed the disease signal on animal cards from a red row to status icons, so you can tell an untreated animal from one under treatment and spot a CVM carrier at a glance.
- Fixed animals dying from a disease they had just beaten - curing an animal, by treatment or by natural recovery, now reliably saves it.
- Fixed cured animals still dying of the same disease all through the months they were meant to be immune - almost no chicken used to survive avian flu, even after recovering from it.
- Fixed every treatment curing after a single month regardless of the disease - Foot & Mouth now runs the full three-month course its treatment is meant to take.
- Fixed animals that had recovered from a disease, and CVM carriers, still being listed as diseased - they now group, sort and filter as healthy, so the Diseased Animals list only shows animals that are actually sick.
- Fixed recovered animals still spreading the disease they beat, so outbreaks now burn out instead of running for the whole immunity window.
- Fixed a sick animal not passing its disease on during the month it recovered or died - the month an infection ended counted as if the animal had never been contagious.
- Fixed the Immune label counting up from when the animal caught the disease instead of counting down the protection it has left.
- Fixed the cured notification arriving a year or two late - it now appears on the month the animal actually recovers, instead of when its immunity runs out.
- Fixed a treatment you stopped part-way reading as Not treated, so the status now agrees with the months left and the Resume button.
- Fixed disease treatment being free - the fee is now taken from your farm balance and shown as a cost, where it used to appear as income and never leave your account.
- Fixed a newly infected animal reporting its infection age as "-1 years, 11 months" in the info box until the next month began. It now reads 0 months.
- Fixed the Diseases button being usable by farm members without the Trade Animals permission - starting a treatment commits the farm to a recurring per-animal fee, so it now follows the same permission as the other animal actions.
- Fixed diseases never reaching other players in multiplayer - a client saw whatever the herd looked like when they joined, so an animal falling ill, being cured, or coming out of immunity went unnoticed until something unrelated happened in that pen. Health and treatment now update as they happen.
- Fixed an animal the server had just cured reading as "Being treated" on other players' screens when treatment was toggled.

### The animal screen and the per-pen herdsman

- Changed every route into the animal screen to open the RL Menu, including ones other mods trigger - some previously opened the old screen and others did nothing at all.
- Stopped replacing the base game's hand-tool sorting on the statistics screen - Realistic Livestock had been overriding it with code that behaved like the base game's, so nothing changes on that screen, but the mod no longer overwrites other mods that adjust it.
- Removed the old animal management screen for good. Browsing and managing animals is unchanged - the RL Menu already handled all of it. In the rare case another mod opens the animal screen in a way the RL Menu cannot take over, you now see the standard Farming Simulator screen instead of the old Realistic Livestock one.
- Removed the old per-pen herdsman, the automation you used to set up on a single animal pen - it has not run since v1.3.0.0, the Herdsman tab in RL Menu replaces it, and its leftover settings are cleared out of your save the first time you save after updating.
- Removed the leftover Mark Animal and Castrate Animal keybindings - they had stopped doing anything, and any custom keys you had set for them are simply ignored now.
- Removed the getAIManager function that other mods could call on a Realistic Livestock animal pen, with no replacement, because the per-pen herdsman it handed back no longer exists.
- Fixed being stranded on the old animal screen with no way out - not even Escape - when another mod opened the animal screen in a way Realistic Livestock could not take over. The RL Menu now opens as intended in that case.
- Fixed the R shortcut being listed as "Open Animal Screen" in the Controls settings, naming a screen that no longer exists - it now reads "Manage Animals" in every language, matching the button it triggers.

### Translations

- Added Spanish as a new language, covering the menus, filters, herdsman, settings, messages and in-game help - it arrives as one of the most complete translations the mod ships (contributed by zarvaoo_16).
- Completed the Dutch translation - the many menu, filter, herdsman, settings and message strings that were still showing in English are now translated (contributed by Nozem1982).
- Completed the Ukrainian translation - the menus, filters, herdsman, settings, messages and in-game help were still largely in English (contributed by Kalderone Daniil_ua).
- Completed the Czech translation - the menus, filters, herdsman, settings, messages and in-game help were still largely in English, and the insemination straw is now named as such rather than as bedding straw (contributed by Mapolap).
- Fixed the herdsman labels in thirteen languages still carrying wording retired two releases ago - among them a budget field that read as a share of herd value when it actually sets a share of your farm money.

### Documentation

- Updated the disease guide's survival tables to match the new post-recovery rules - a cured animal faces no further risk from the disease it beat until its immunity lapses.

## 1.3.1.0:
### Heads up before you update
Things that affect existing saves:
- Dealer animal genetics follow a natural bell curve now. An "Extremely good" animal drops from roughly one in 25 to under one in 200, and "Very bad" ones from about one in 20 to about one in 160. Existing dealer stock is untouched and converges to the new curve as the dealer restocks.
- Saved genetics filters and herdsman goals keep their stored 0-99 thresholds but now cover a different share of dealer stock. A filter like "overall genetics at least 90" goes from a few percent of the dealer's animals to well under one percent. If a saved filter suddenly returns nothing at the dealer, lower its threshold.
- Changing "Dealer Animal Quality" discards the current dealer stock and restocks with new animals.

### Added
- Added "Choose Animals For Sale" in RL Menu > Settings > General - pick which animals and age groups the animal dealer offers, and the dealer restocks to match. Admins can change it in multiplayer, and every player's dealer updates to match.
- Added "Dealer Animal Quality" in RL Menu > Settings > General - choose whether the animal dealer stocks Budget, Standard or Premium animals. Budget stock is weaker and cheaper; Premium stock is stronger and costs more. Changing it discards the current dealer stock and restocks with new animals, and it does not affect the AI animals used for insemination. Admin only in multiplayer.
- Added "Horse Care" as a Herdsman task - it exercises and grooms the horses in a chosen horse pen every day so their Daily Riding and Cleanliness stay up and they hold their sale value, charging a wage for every horse it looks after.
- Added a "Select Section" control to "Choose Animals For Sale" - the S key, or its button, ticks or unticks just the animal group you are on and leaves the rest of the list alone.
- Added a note on each Herdsman task setting that is required but empty, or that holds a number outside its allowed range, so a task that will not run now tells you which field to repair instead of showing the same neutral prompt as a setting you simply have not filled in yet.

### Changed
- Changed animal dealer quality to follow a natural bell curve instead of piling animals up at the best and worst extremes. Most dealer animals are middling: an "Extremely good" one drops from roughly one in 25 to under one in 200, "Very bad" ones from about one in 20 to about one in 160, and an animal's traits now sit closer to each other. Existing dealer stock is untouched and converges to the new curve as the dealer restocks.
- Changed what saved genetics filters and herdsman goals match - they keep their stored 0-99 thresholds but now cover a different share of dealer stock because of that curve change, so a filter like "overall genetics at least 90" goes from a few percent of the dealer's animals to well under one percent. If a saved filter suddenly returns nothing at the dealer, lower its threshold.
- Changed the Herdsman task editor to put the task's on/off switch at the bottom of its settings instead of near the top - you fill in the job, filter and pens first and switch the task on last.
- Changed Space in "Choose Animals For Sale" to tick or untick the whole list at once instead of only the group you were on, matching every other multi-select list in the mod.

### Fixed
- Fixed the animal dealer's poorest stock lingering forever on established saves - listings now rotate off the shelf after at most two in-game days.
- Fixed a Herdsman task keeping a filter its new job cannot use when you change the Operation - the filter and any now-unsuitable pens are cleared, so the task can be repaired instead of being stuck with a filter the picker will not offer.
- Fixed a change to an already-enabled Herdsman task being thrown away when it left the task incomplete - the task is now switched off for you and keeps your change, ready to finish and switch back on.
- Fixed saved filters and herdsman rules being lost (and overwritten on the next save) when loading a save that has no Realistic Livestock animal data.

### Translations
- Fixed stray characters that had been shipping in ten of the translation files.

### Documentation
- Added user-guide coverage for the two new dealer controls and the Herdsman's Horse Care task, plus a FAQ entry on why a pen can show only one animal in husbandry.
- Fixed the user guide still listing a Shift + T keybind for the visual-animals control - that key was removed when the control moved into RL Menu > Settings > General.

### Compatibility
- Listed the Sheep Breeds Pack for RLRM alongside the Cow Breeds Pack as a supported animal pack.


## 1.3.0.1:
- Improved the saved-filter editor - comparison operators now read as plain English ("is at least", "is one of", "does not contain", ...) in the Compare dropdown and each condition row, instead of programmer symbols.
- Fixed the saved-filter editor showing the Gender, Breed, and Name fields as raw internal names in the field picker and condition rows.

## 1.3.0.0:
### Heads up before you update
Things that affect existing saves:
- The old herdsman automation no longer runs. Set up your automation again in the new Herdsman menu.
- The old animal screen is removed: your pens, on-foot dealers, the R key, and trailer-to-butcher deliveries all open the new RL Menu now.
- All mod settings moved into the RL Menu's Settings tab; the in-game Settings page is now a single button that opens it.
- Breeding ages were adjusted (goats from 8 months, horse stallions from 24, hens stop hatching by ~5 years, roosters retire at 6), so existing herds breed on a slightly different schedule.
- The "max visible animals" control moved to RL Menu > Settings > General (the Shift+T key was removed).

### New livestock menu
- Added the RL Menu as the mod's main animal-management interface - a standalone tabbed menu.
- Added opening it from anywhere with your own key (default Right Shift + O, set in Controls), plus from your pens, on-foot dealers, the R key, and trailers.
- Added memory of your selected pen and animal as you switch tabs, with the husbandry list sorted alphabetically.
- Added status icons on every animal card - pregnancy, recovering, infertile or castrated, lactating, producing wool, and laying eggs.
- Added a Manage tab - animal list with a detail pane (pedigree, genetics, diseases, inputs and outputs) plus per-animal actions: Mark, Monitor, Rename, Diseases, Inseminate, Castrate. Genetics shown as a 0-99 score next to each trait.
- Added a Messages tab - chronological feed with single and bulk delete.
- Added a Move tab - move animals between pens or deliver them to a butcher, one or many at a time; a feed-runway estimate shows how many months the current feed lasts.
- Added a Sell tab with a shopping-cart summary (count, price, fee, total).
- Added a Buy tab - browse dealer animals with per-row prices and a running cart total; buy one or many via a destination picker.
- Added an AI tab - browse dealer bulls by species, pick a straw quantity with live price preview, favourite bulls, and buy straws without leaving the menu.
- Added Saveable Filters - build reusable filters in-game (Settings > Filters) on age, gender, pregnancy, lactation, genetics, subtype, weight, health, marks, and name; multi-value "in / not in" via a Select Values dialog; cross-species matching when Animal type = ANY.
- Added F on the Manage/Buy/Sell/Move tabs to cycle filters (shown as a chip), with a per-filter "Show on" axis (All / Owned herd / Dealer) to keep the cycle tidy, and one-click saving of the current Quick Filter as a reusable filter.
- Added a Settings tab - all mod settings now live here instead of on the in-game settings page, including a new "Animal Country of Origin" setting that chooses the country new animals are registered in (ear tags, identifiers). New animals only.
- Added trailer handling in the menu - move animals between a pen and a parked trailer, buy into or sell from a trailer at the dealer, and load or unload horses from a standalone trailer out in the world.
- Added a Herdsman tab - create, duplicate, and delete named automation tasks; each runs one action (sell, buy, castrate, naming, AI insemination, or move) on the animals matched by a saved filter across the pens you choose. A move task can target a butcher (Extended Production Point); animals outside its age range are skipped and reported.
- Added a task editor - name, enable or disable, per-action options (animals per day, budget, naming convention, AI semen choice), and a choice to mark matching animals for review or perform the action outright, with per-row help tooltips.
- Added automatic day-change task runs, server-side, in order (sell, buy, castrate, naming, AI, move), respecting each task's cap, budget, and the destination's free space; a herdsman wage applies per farm. The herdsman reports what it did in the Messages tab (folded into daily counts when message summary mode is on).
- Added server-authoritative multiplayer for everything in the new menu - it syncs to all players, open menus refresh live, and late-joining players receive the full filter and rule set.
- Added new user guides for Saved Filters and Herdsman automation, and made the user guide site downloadable as a PDF.

### Multiplayer fixes
- Fixed husbandry log messages (animal buy/sell/move, births, deaths, and daily summaries) appearing only after rejoining instead of live for connected players.
- Fixed inseminating a female from the menu silently doing nothing on dedicated servers and clients (no pregnancy, and a straw was wasted); straw counts now stay in sync across all players.
- Fixed a mother's post-birth recovery appearing stuck as "recovering" instead of counting down live, which had wrongly blocked inseminating her again until a relog.
- Fixed rapidly triggering two animal trades of the same kind (buy, sell, or move) risking the wrong animals or leaving the menu stuck - trades now run one at a time with a "trade in progress" notice and timeout recovery.
- Fixed animals from a DLC that is installed but not active in the session being loaded, which showed them as the wrong breed or gender, or corrupted them when bought, for players without the DLC.

### Fixed
- Fixed cows on Hof Bergmann v1.4 cow pastures not producing milk (all cow breeds produce milk cans again).
- Fixed the pen feed forecast under-estimating the months-of-feed range at higher days-per-month settings - it now reflects the real days of feed remaining.
- Fixed a declined semen purchase (e.g. not enough money) using up dealer spawn space, so repeated declined attempts can no longer eventually make valid purchases fail with a "no space" message.
- Fixed an FPS stutter when switching the active implement (G) - the animal-visibility settings dialog now loads once per session instead of on every switch.
- Fixed pressing Esc in an animal pen's menu opened from the in-game menu (Animals page) closing straight to the game instead of returning to the in-game menu.

### Compatibility
- Documented that the LSFM Animal Transport Pack's animal herding/driving feature does not work with RLRM (it opens the animal screen through the pack's custom transport object, which the new menu does not recognise); the rest of the pack is unaffected. Hof Bergmann bundles this pack - see the mod-compatibility guide.

## 1.2.6.0:

### Added
- Added trailer loading and unloading at a pen - walk up to a parked livestock trailer to move animals between the pen and the trailer.
- Added trailer buying and selling at the dealer - with a trailer present, the Buy tab buys animals straight into the trailer and the Sell tab sells straight from it.
- Added standalone trailer handling out in the world - walk up to a parked trailer to load loose horses into it and unload them back out.
- Added a Herdsman tab in the RL Menu - create, duplicate, and delete named automation tasks. Each task runs one action (sell, buy, castrate, naming, AI insemination, or move) on the animals matched by one of your saved filters, across the pens you choose.
- Added a herdsman task editor - set a name, enable or disable the task, configure its options (animals per day, budget, naming convention, AI semen choice), and choose whether the task marks matching animals for review or performs the action outright. Per-row help tooltips explain each option.
- Added filter and target-pen pickers inside the task editor - the filter list is scoped to the task's action (buy draws from the dealer pool; sell, castrate, and AI from your own herd) and the pen list to the filter's animal type. A task needs a filter and at least one pen to be enabled, so incomplete drafts can be saved disabled.
- Added automatic day-change task runs, server-side, in order (sell, buy, castrate, naming, AI, move), respecting each task's animal cap, budget, and the destination pen's free space. A herdsman wage is deducted per farm.
- Added day-change notifications - the herdsman posts the same per-pen messages the legacy herdsman did (sold, bought, castrated, named, inseminated, moved, or "marked for ..."), folded into daily counts when message summary mode is on.
- Added an orange banner warning when a pen still has the legacy herdsman enabled - the menu-based tasks run alongside the legacy per-pen herdsman, not instead of it, so avoid running both for the same pen or actions and wages get applied twice.
- Added multiplayer sync for herdsman tasks - create / edit / delete sync to all players and an open menu refreshes live; the day-change actions replicate to clients, including on dedicated servers.

### Changed
- Changed livestock trailers to load and unload in the RL Menu instead of the legacy animal screen.
- Changed trailer transfers to run server-side through the same events the legacy screen used, so they sync to all players, including on dedicated servers.

### Fixed
- Fixed goats showing wool instead of milk production in the animal genetics overview, across the RL Menu, the legacy info dialog, and the on-foot look-at panel.
- Fixed pregnancies not tracking each animal's configured gestation period closely, especially at higher days-per-period settings where they previously ran too long (contributed by borondy).
- Fixed young animals maturing far too fast at higher days-per-period settings - they now grow to full size over their proper age range (contributed by borondy).
- Fixed settings changed in the RL Menu (Settings > General) not syncing to the server in multiplayer - they now persist across save/reload and update live for other players, where previously these changes were silently lost on dedicated servers.
- Hardened against a possible crash when a mod or game code path looked up a missing (nil) text label - the lookup now falls back safely instead of stopping the game, and logs a warning.

### Translations
- Fixed the Danish herdsman sell tooltip to show the specific sell age again instead of a vaguer phrasing that dropped it.
- Added French translations for the new herdsman task editor, filter editor, daily-summary, mod-compatibility, and saved-filter strings that were still showing in English (contributed by squall39).
- Fixed the German animal-move confirmation showing a leftover price that the other languages never displayed.
- Updated Italian with a native-speaker refresh across the menu, settings, and help text, plus the herdsman move strings that were still showing in English (contributed by FirenzeIT).
- Added Turkish translations for the many menu, herdsman, settings, and message strings that were still showing in English (contributed by Cyber-Syntax).
- Changed new filter and herdsman labels to fall back to English instead of showing raw text codes in languages that have not translated them yet.

### Compatibility
- Changed FS25_AnimalFoodCalculator to a blocking conflict instead of a dismissible warning - it breaks RLRM's animal feeding and milk/egg/wool output, so the game stops and prompts a restart to disable it.

## 1.2.5.0:

### Added
- Added a mod compatibility bridge - RLRM can now coexist with some foreign mods that overlap its hooks, via per-mod shim files in `mod_support/<ModName>/` (same layout as the map-support bridges). The framework activates automatically when a registered foreign mod is detected; shim files self-disable cleanly when their target mod is absent, with no impact on RLRM-only setups.

### Changed
- Improved Hereford calves to use the breed-accurate red-and-white coat (adults shipped in 1.2.4.0; UV-layout tip from [MA] BavarianRedneck).
- Changed quick filter persistence to be tab-local and shown in the chip ("QF" alone or combined with a saved-filter name); it clears automatically when you leave the tab.

### Fixed
- Fixed selling or buying animals via a livestock trailer at the dealer logging `Error in AnimalSellEvent` / `Error in AnimalBuyEvent ... missing method 'addRLMessage'`. The sales themselves always completed.
- Fixed animal lists showing wrong breeds or species in multiplayer on clients missing a DLC the server has installed (e.g. Highland Cattle rendering as Water Buffalo). Server data was always correct; only the receiving client misrendered.
- Fixed player-initiated insemination from non-host clients not propagating to the server and other clients within one network frame (previously applied locally only).
- Fixed empty dewars (0 straws remaining) surviving save/load or a storage round-trip; they now self-delete on the server in every code path. Affected saves clean up on next load.
- Fixed newborns of the same farm inheriting "Children" counts from another species' male with the same identifier (e.g. a Texel ram showing 61 children due to a rooster collision). Existing bogus counts are not auto-cleaned.
- Fixed the AI insemination "not enough money" check not blocking dewar purchases priced above farm balance (both RL Menu AI tab and the legacy R-key flow).
- Fixed the Artificial Insemination dialog's Inseminate button staying latched to the first row instead of enabling and disabling per selected dewar.
- Fixed per-visual `canBeBought="false"` on animal sale stages being silently ignored at the dealer. Packs can restrict a breed to juvenile-only or adult-only sales; default bundle behavior unchanged.
- Fixed pens overflowing past capacity when multiple pregnancies mature on the same day-change. Existing overcap saves heal gradually via natural deaths or sold animals.
- Fixed defensive pregnancy backfill on legacy / orphaned saves passing nil instead of the mother's quality for offspring of mothers missing `impregnatedBy.quality`. Normal pregnancies were always correct.
- Fixed the quick filter dialog silently applying a "Healthy animals only" filter on open + OK; the disease filter now defaults to any.
- Fixed quick filter dialog polish - added a title, aligned the scrollbar inside the dialog body, stopped clamping slider ranges to a previously-applied filter, and fixed option rows drifting to the wrong segment or slider thumb after scrolling. Applies to both the new RL Menu and the legacy R-key screen.
- Fixed Settings > General not being admin-only end-to-end. Non-admin players could previously edit most rows; changes would revert or briefly affect the server.

### Documentation
- Documented the Hof Bergmann support page and FAQ - the HB bull stable's BULLSPERM trigger stays empty under RLRM (HB models bull sperm as a milk output; RLRM only produces milk for lactating female cows). HB pasture bulls remain decorative.

### Compatibility
- Added Seasonal Wool Production (Argsy Gaming) compatibility - RLRM and SWP now coexist without the previous double-production of wool. SWP handles wool as a seasonal event with a single output per sheep per season; per-pen yield matches vanilla SWP based on flock size (mature sheep aged >= 8 months). Trade-off: wool yield does not reflect RLRM per-animal genetics.

### RL Menu (preview - work in progress)
- Added in-game editing of Saveable Filters from Settings > Filters. All engine field types supported (numeric, boolean, gender, subType, name); multi-value "in" / "not in" via a Select Values dialog; cross-species matching when Animal type = ANY. Out-of-range numeric values are rejected with a visible hint.
- Added a per-screen "Show on" axis (All / Owned-herd / Dealer) to Saveable Filters so the F-cycle stays uncrowded once you have several filters.
- Added a Save filter button to the Quick Filter dialog that turns the current dialog state into a new saveable filter and opens Settings > Filters on the new row. Price conditions cannot be saved and are dropped with a warning.
- Added a feed-runway estimate to the Pen Info and Move tabs in the "Total Capacity" row - a `(~N-Mm)` range shows how many in-game months the current feed lasts, accounting for lactation, gestation surge, scheduled births, and per-animal metabolism. The capacity bar and text turn red when the runway drops below 2 months.
- Changed Settings > Filters so New filter / Duplicate picks the next free suffix as max existing N + 1, so names no longer collide after deleting earlier-numbered entries. Saved-filter cards now use the dealer-card visual style so more fit on screen.
- Changed the Animal Dealer to open the new RL Menu (Buy tab) at the shop counter and on walk-up; trailer loading still uses the legacy screen.
- Fixed filter create / rename / delete not refreshing peer Info / Buy / Sell / Move tabs live in multiplayer, which needed a menu reopen.
- Fixed RL Menu tab and header icons rendering at about half base-game size.

### Herdsman automation rules (preview - backend groundwork, no in-game UI yet)
- Added the foundation for upcoming saveable Herdsman rules that pair a saved filter with an automated operation (sell, buy, castrate, naming, or AI) across chosen pens. Rules persist across save/load in rm_RlSettings.xml; a corrupt or hand-edited rule record is dropped safely on load. Multiplayer: rule add / edit / delete propagate to all players, and a player who joins mid-session receives the server's full rule set on connect.

## 1.2.4.0:

### Added
- Added map support for Le Mechet by MA7Studio (https://farming-simulator.com/mod.php?mod_id=357964) - four French cow breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) with bull variants; full breeding, genetics, and reproduction; per-breed pricing, milk curves, and reproduction signatures preserved from the map's source XML.
- Added an in-game warning when two map bridges or animal packs replace the same animal type's husbandry. The second one wins and the first one's animals can become invisible (ghost animals); RLRM now shows a dismissible warning at mission start so the cause is visible instead of silent.
- Added clean loading of Witcombe Park Farm 1.3.0.0 (v4) with the existing map bridge.
- Added saveable animal filters - define filters that match on age, gender, pregnancy, lactation, genetics, subtype, weight, health, marks, and name, nested with AND/OR groups; filters persist across sessions in the savegame. For now filters are authored by hand-editing rm_RlSettings.xml - the in-game editor ships in a future release.
- Added F on the Info / Buy / Sell / Move tabs to cycle through saved filters; the active filter shows as a chip on the tab. Filter selection is shared across Info / Move / Sell; Buy keeps its own selection per dealer flow.
- Added multiplayer sync for filter create / update / delete across all connected players (admin or tradeAnimals permission required); late-joining clients receive the full filter set on connect.
- Added a Settings tab with two subtabs - [General] surfaces the existing RL settings (now editable from both the new menu and the legacy GAME SETTINGS page, reordered into thematic groups: Mortality, Health & Disease, Husbandry & Economy, Custom Animals, Message Log, Display Preferences, Tools & Admin), and [Filters] lists your saved filters (read-only view today; in-game editor in a future release). Toggling a setting on either General page reflects on the other when re-opened.

### Changed
- Improved the Hereford adult cow and bull skin to a more breed-accurate red-and-white coat. Texture contributed by [MA] BavarianRedneck.

### Fixed
- Fixed the finance overview showing the `Missing 'finance_medicine' in l10n_en.xml` fallback instead of "Medicine" for animal medicine costs.

### Translations
- Improved the French translation with a refresh by community contributor @squall39 (PR #83) - native-speaker corrections to existing strings and translations for the new RL Tabbed Menu strings (Messages, Info, Move, Sell, Buy, AI tabs).

### Documentation
- Improved the user guide cattle milk chart to reconcile with the breed-range table; a footnote spells out which factors compose into the table range (the chart is the lifetime age envelope; the table folds in lactation-phase factor and genetics multiplier).
- Added a Filter Hand-Crafting reference page in the user guide for power users authoring saveable filters in rm_RlSettings.xml until the in-game editor lands.

### Compatibility
- Documented that Le Mechet is NOT compatible with the Cow Breeds Pack for RLRM (FS25_CowBreedsRLRM) unless you use the latest development version of the Cow Breeds Pack - both replace the cow husbandry config and only one can win. Use Le Mechet alone, or pair it with the latest dev Cow Breeds Pack. The new in-game warning will fire if you load both together.
- Removed Hereford from the dealer when Le Mechet is the active map.

## 1.2.3.0:

### Added
- Added a non-blocking startup warning for known-trouble mods - a dismissible dialog at game start with a link to the new Mod Compatibility reference page; hard-conflict mods are unchanged.
- Added support-log diagnostics for lag triage and bug reports - per-pen timing summaries for day-change/cluster-update/visual-update/buy operations, an `rlDumpSettings` console command, and a one-time startup dump of active RL settings (set log level to DEBUG to see timing detail).

### Changed
- Improved bulk animal operations (move, sell, buy, AI sell) and multiplayer sync of reproduction/death cycles - large herds no longer freeze the game; clients receive a single update per affected husbandry instead of one per animal; day-change with simultaneous births collapses to one cluster-update per pen.
- Changed pregnancy food and water consumption to cap at 2x the non-pregnant baseline (previously sows with large litters reached 4-9x during late gestation; cattle and sheep with typical litters are unaffected). Builds on contributor PR #72 - thanks @borondy.

### Fixed
- Fixed the multiplayer hard-conflict dialog not firing on every peer; pure clients connecting to a host with a known-conflict mod are now returned to the main menu instead of silently entering a broken session.
- Fixed pregnant and lactating cows/goats not actually drinking more water - the multiplier was being computed but silently discarded.
- Fixed pregnancy state occasionally clearing the pregnant flag inconsistently after an internal cleanup, which affected pregnancy sync across multiplayer peers and sale animals at the dealer.
- Fixed a multiplayer error that left pig and horse pregnancies unsynced to clients (both natural conception and AI-straw insemination would appear to succeed on the host but never replicate to other players).
- Fixed a multiplayer crash on per-animal load/unload from the trailer animal screen - clicking the single-row load button crashed the client and corrupted the move packet on the server. Multi-select bulk was the only working path until now.
- Fixed rabbits on Witcombe never getting pregnant - the Witcombe bridge now ships a fertility-by-age curve for the RABBIT type.
- Fixed Witcombe Highland Cattle rendering as a small Angus calf at all ages and Witcombe Herefords rendering as Limousin-coloured Angus instead of the white-face Hereford. Witcombe's custom Hereford dealer-menu thumbnails are preserved.
- Fixed Jersey cows on Witcombe showing the marker spray and monitor collar permanently regardless of actual state; the same fix applies to Witcombe-bridge sheep and pig breeds (Texel / Suffolk / Blue-Faced Leicester rams, Gloucestershire Old Spot boar) and Hereford bulls.
- Fixed the marker tool crashing on Jersey or Highland (added cream and auburn marker colours; unregistered breeds fall back to white).
- Fixed the RL Menu Messages tab not clearing the per-pen unread flag on open; existing saves with stuck unread flags will auto-heal the first time you open the Messages tab.
- Fixed redundant "animals changed" notifications firing multiple times per mutation.

### Documentation
- Added a Breeding Reference page in the user guide - per-breed table of female and male breeding ages, gestation, and peak litter sizes across all base species.
- Fixed user guide accuracy - Witcombe Hereford peak (the value at 18 months is not the peak; the peak is at 24 months), PED disease fatality framing (time-since-infection rather than age-when-infected), and lactation-bonus wording.

## 1.2.2.0:
- Added Witcombe map support - new UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) with full breeding, genetics, and reproduction; rabbits get viable weights, litter sizes, and consumption rates; automatic version-aware compatibility
- Added a Buy tab to the RL Menu (preview) - browse dealer animals, see per-row prices and a running cart total, then buy one or many at a time via a destination-picker flow
- Added an Artificial Insemination tab to the RL Menu (preview) - browse dealer bulls by species, pick a straw quantity with live price preview, favourite bulls, and buy straws without leaving the menu
- Changed Hereford on Witcombe to use a heritage breed profile - 9-month gestation, premium pricing (300/3000), and an 18-month sell-price peak
- Changed Info tab genetics to show a 0-99 score next to each label (e.g. "97 - Extremely high") so animals within the same bucket can be compared at a glance
- Fixed the RL Messages tab not showing "Bought/Sold N animal(s) for €X" entries in singleplayer after buying or selling (previously these entries only appeared in multiplayer)
- Fixed a potential multiplayer crash when changing monitor, name, or disease treatment on an animal while the husbandry is being sold or demolished
- Fixed the multiplayer insemination result notification to clients reporting success when the insemination actually failed
- Fixed the RL Menu (preview) Sell and Info tabs showing a stale farm balance until the next action instead of refreshing immediately in multiplayer

## 1.2.1.0:

### Added
- Added multiplayer support for the "Reset Animal Dealer" and "Reset AI Animals" buttons (admin-only in MP, syncs to all players)
- Added a Sell tab to the RL Menu with a shopping cart summary (selected count, price, fee, total); animals marked as non-sellable are filtered out

### Changed
- Changed the husbandry selector to sort alphabetically by name
- Changed the RL Menu to remember the selected husbandry and animal when switching between Manage, Move, and Sell tabs
- Renamed the "Info" tab to "Manage" to better reflect its actions (mark, inseminate, monitor, etc.)
- Reordered the tabs to Sell, Move, Manage, Messages

### Fixed
- Fixed straw pickup from a dewar not syncing to the server in multiplayer (the dewar no longer "refills" on reconnect)
- Fixed the empty straw hand tool not being deleted from client inventory after insemination or return in multiplayer
- Fixed animal mark/unmark not updating the 3D visual marker immediately when unmarking (previously required relog)
- Fixed a potential multiplayer crash when receiving unknown mark keys from newer mod versions
- Fixed a straw hand tool crash when no player is carrying it
- Fixed a crash when selling an animal from a livestock trailer at the animal dealer
- Fixed a crash when opening the animal trailer screen near a rideable horse created by third-party mods (e.g. AdditionalContracts animal missions)
- Fixed prop horses from third-party mods being incorrectly converted to real animals when loaded onto trailers or into pens
- Fixed animals marked as non-sellable being sellable after loading onto a trailer
- Fixed single sell/move clearing other checkbox selections
- Fixed status icons jumping position when switching between tabs
- Fixed animal age not showing in the RL Menu stats area

## 1.2.0.1:
- Fixed deprecated fillUnit warning in game log for semen dewar

## 1.2.0.0:

### Added
- Added the new RL Menu (assign key in Settings > Controls) - a standalone tabbed menu. The legacy animal screen (R key) still works unchanged
- Added a Messages tab - chronological message feed with single and bulk delete
- Added an Info tab - husbandry selector, animal list with detail pane (pedigree, genetics, diseases, inputs/outputs), and action buttons (Mark, Monitor, Rename, Diseases, Inseminate, Castrate)
- Added a Move tab - move animals between husbandries or to butchers with single-move and bulk-move using checkbox multi-select
- Added status icons on animal list cards showing pregnancy, recovering, infertile/castrated, lactating, producing wool, and laying eggs at a glance

### Changed
- Rewrote the semen dewar as a vehicle/pallet - fixes game freeze when looking at the dewar, multiplayer pickup failures, and invisible dewars after mid-game purchase
- Changed dewar state (straws, bull genetics) to persist through save/load and object storage cycles

### Fixed
- Fixed a crash in third-party mods that inspect stored pallets (e.g. Time Saving Stock Check) when a semen dewar is placed in object storage
- Fixed multiplayer desync - mark, castrate, monitor toggle, rename, and disease treatment changes from a client now sync to all other connected players
- Fixed all pre-existing animals getting the same identity (e.g. "UK 1 1") when installing RL on an existing save for the first time - also self-heals saves already affected
- Fixed fillType errors in the log when third-party selling station mods reference the ANIMAL category

### Translations
- Updated the Czech translation (community contribution by Kynuska)
- Added the Hungarian translation (community contribution by Toamsz93)
- Added missing translation keys across all 16 languages

## 1.1.4.0:
- Added diagnostic logging for fillType mismatches in pallet and milk output
- Disabled four horse breeds not natively supported by Hof Bergmann (Pinto, Chestnut, Bay, Dun) from the dealer - existing savegame horses of those breeds are unaffected
- Fixed horse breed visuals on Hof Bergmann - adult horses no longer display as foals, breed colors now match correctly, and the foal-to-adult model transition now works
- Fixed horse riding and equipment on Hof Bergmann v1.4 - saddles, carriages, and tools from the Horse Addon Pack now attach correctly
- Fixed the dealer generating sale animals for breeds marked as not purchasable on the current map
- Fixed wool not spawning on Hof Bergmann v1.4 - the bridge now remaps WOOL to SHEEPWOOL_SHEARED to match HB's husbandry buildings
- Fixed chicken eggs not spawning on Hof Bergmann v1.4 - the bridge now remaps EGG to EGG_HB to match HB's husbandry buildings
- Fixed the Hof Bergmann egg incubator failing to add hatched chicks to the husbandry when RLRM is active
- Fixed a crash when an animal output curve returns nil, which could silently stop all production in a building
- Fixed bridge output overrides replacing valid production curves with empty ones when only the fillType needed remapping
- Fixed the Hof Bergmann user guide's horse breed availability, riding notes, and wild duck clarification

## 1.1.3.0:
- Added pre-validation for bulk buy - shows which animals can't be purchased and why before confirming
- Added diagnostic logging for animal loading, breeding, and pack compatibility troubleshooting
- Added warnings when animals are lost due to removed packs or breed mismatches
- Fixed bridge animals (rabbits, quail, etc.) getting duplicate IDs in multiplayer, causing animals to disappear on clients
- Fixed the bridge animal ID counter, which now tracks per-type counters with savegame persistence
- Fixed bulk buy silently failing when map husbandries reject animal breeds (e.g. Hereford in Hof Bergmann filtered pens)
- Fixed existing saves with duplicate bridge animal IDs, which are now automatically repaired on load

## 1.1.2.0:

### Added
- Added an animal pack system - third-party mods can add breeds, override animal properties, or provide custom balance via rlrm_pack.xml
- Added Hof Bergmann 1.4 support with alpacas, quail, corrected chicken visuals, and version detection
- Added cross-color alpaca breeding (any male color can breed with any female color)
- Added an exit path so the RL animal screen returns to the in-game menu's Animals tab when opened from there
- Added an Info-tab default so the RL animal screen opens on the Info tab when entered from the in-game menu's Animals tab

### Changed
- Refactored Animal.lua internally into focused modules (reproduction, health, persistence, serialization)

### Fixed
- Fixed the animal list scroll position jumping every 5 seconds in the ESC menu's Animals tab
- Fixed a click sound playing every 5 seconds while viewing the animal list
- Fixed a crash when a husbandry doesn't register a pallet or milk fillType that its animals produce
- Fixed animal model accumulation when maps redefine existing animal types
- Fixed base game reloads clobbering RLRM's superset animal configs
- Fixed random death money compensation (33% sell price) not reaching the farm balance
- Fixed bridge animal descriptions showing "Missing" in the animal info dialog
- Fixed pig ear tag errors on Hof Bergmann maps
- Fixed sale animals of non-reproductive subtypes (e.g. bulls, dogs) incorrectly becoming pregnant
- Fixed bridge animals' offspring receiving the wrong breed when using a non-standard subtype layout
- Fixed map-defined subtypes for existing animal types not loading alongside base game configs

### Translations
- Improved the Italian translation (community contribution)
- Improved the German translation (community contribution)

### Documentation
- Added user documentation for Hof Bergmann map support (exotic animals, known limitations, FAQ)

## 1.1.1.0:
- Added version-aware map support - detects installed map version and loads the matching configuration
- Added warning dialog when an untested map version is detected (with link to report issues)
- Added breed and visual override support for map-based animal subtypes
- Fixed division-by-zero risk in horse riding fitness calculation at boundary threshold values
- Fixed horse riding value not being clamped (could accept values outside 0-100 range)
- Fixed male animals could theoretically become pregnant (missing gender guard in reproduction check)
- Fixed AI herdsman castrate notifications showing "marked for castrating" instead of "castrated" when in execute mode
- Fixed AI herdsman state tracking error after auto-buying animals
- Fixed BUM ID branding on cows showing all zeros and overlapping text

## 1.1.0.3:
- Fixed selected animal jumping to a different animal in the in-game animal menu

## 1.1.0.2:
- Changed invalid messages to be discarded on savegame load and handled gracefully in the UI
- Fixed crash on Messages tab caused by unrecognized message IDs from older dev versions

## 1.1.0.1:
- Fixed crash when moving animals between pens (nil subtraction on visual animal count)

## 1.1.0.0:
- Added Move tab for transferring animals between husbandries with destination picker and bulk move
- Added custom icons for all Animal Screen tabs
- Hid the castration tab in the herdsman screen for chickens (not applicable)
- Refactored internally for code quality and testability
- Fixed visual glitch in herdsman screen when enabling castration

## 1.0.2.0:
- Added genetics display in animal names (average score, or full breakdown per trait)
- Added sort by genetics option for animal lists
- Added selection count on bulk action buttons
- Fixed move messages in husbandry message log (were silently failing due to incorrect message keys)
- Fixed move messages showing wrong direction (to/from was swapped)
- Fixed typo in move message ("1 animals" -> "1 animal")

## 1.0.1.1:
- Fixed compatibility with Hof Bergmann's subtype filter for animal pens

## 1.0.1.0:
- Added Hof Bergmann map support - exotic animals (ducks, geese, cats, rabbits) now support full breeding and reproduction
- Added basic support for butchers using Extended Production Point (EPP) mod
- Improved offspring subtype selection for maps with non-standard animal configurations
- Fixed "Manage Animals" (R) key interfering with other mods' keybindings in different menu tabs (e.g. RemoveContract)
- Fixed bulk move allowing more animals than target pen capacity
- Fixed error when moving animals to Extended Production Points (EPP butchers)
- Added missing translation keys across all languages (sourced from EnhancedLivestock where available)
- Updated Italian translation (contributed by FirenzeIT)

## 1.0.0.0 (Stable):
- Added "Manage Animals" (R) button to in-game animal menu for quick access to animal management
- Added "Select" (A) action to check/uncheck selection boxes in buy and sell dialogs
- Changed the insemination button to be disabled when a female is ineligible (pregnant, too young, recovering)
- Changed the monitor button to show a "Removing..." state when removal is pending
- Fixed keybinding collisions - each action now has a unique key (D=Diseases, C=Castrate, M=Monitor, I=Insemination, X=Mark)
- Fixed info buttons (Mother/Father/Children) intercepting Mark/Castrate keypresses - now mouse-only
- Fixed insemination button incorrectly showing on male animals
- Fixed monitor visual not disappearing when removing monitor from animal
- Fixed batch "Remove All Monitors" button not reflecting pending removal state
- Fixed milk/wool/goat milk info not showing on dedicated server clients

## 0.6.1.0 (2026-02-16):
- Fixed AI dialog insemination not syncing in multiplayer
- Fixed AI dialog insemination blocked for cows that never gave birth
- Fixed server crash when client inseminates cow with straw
- Fixed stream corruption in AI auto-insemination event
- Fixed pregnancy event silently failing to match animals on client
- Fixed dewars bought mid-game not syncing to connected clients in multiplayer
- Fixed client-side error when buying semen in multiplayer
- Fixed disease treatment toggle not syncing to server in multiplayer
- Fixed settings dependency check using undefined variable
- Fixed error spam when dismounting horse outside pen in multiplayer
- Fixed black screen when multiplayer client tries to ride a horse
- Fixed multiplayer client unable to clean horses

## 0.6.0.0 (2026-02-13):
- Added daily summary mode for message log
- Added "Reset AI Animals" button to settings
- Fixed freeze when selling animals with active filter
- Fixed possible milk production loss from birth errors
- Fixed missing texture declaration causing visual glitches
- Merged community translations
- Added a user documentation site with per-species guides
- Added FS25_EnhancedLivestock as an incompatible mod

## 0.5.0.0 (2026-01-31):
- Added compatibility handling for FS25_MoreVisualAnimals conflict
- Improved pregnancy handling
- Fixed wrong text string for water/straw in monitor menu
- Added Italian (it) translation

## 0.4.2.0 (2026-01-24):
- Improved fallback handling for days per month calculation
- Improved failover for animal subtypes and breeds

## 0.4.1.0 (2026-01-22):
- Fixed wrong text for when females can reproduce
- Fixed death message count for auto-sold newborns
- Fixed crash with invalid animal root node in visual animals

## 0.4.0.0 (2026-01-18):
- Removed Font Library dependency by inlining 3D text rendering directly in the mod

## 0.3.0.0 (2026-01-18):
- Added the initial Ritter version, based on Arrow-kb's Realistic Livestock v1.2.0.5
- Added automatic savegame migration from Arrow-kb's Realistic Livestock
- Added Highland Bulls support (based on Renfordt's PR 389)

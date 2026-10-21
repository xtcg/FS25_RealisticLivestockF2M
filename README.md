# Realistic Livestock: Farm to Market

A Realistic Livestock Production & Economy Expansion for Farming Simulator 25

[中文版](README.zh-CN.md) · [User Guide](https://xtcg.github.io/FS25_RealisticLivestockF2M/) · [GitHub Issues](https://github.com/xtcg/FS25_RealisticLivestockF2M/issues) · [Downloads](https://github.com/xtcg/FS25_RealisticLivestockF2M/releases)

Livestock farming is more than feeding animals, waiting for them to grow, and selling them.

Realistic Livestock: Farm to Market aims to make animal husbandry a more complete farming experience, where genetics, breed characteristics, feeding strategies, growth, reproduction, processing costs, and market conditions all matter.

## 0.2.0.0 defaults

New saves use Real-equivalent nutrition by default, and the sheep and pig v2 growth models are enabled. Cattle growth, body condition and calf rearing remain enabled. Existing saves retain their saved nutrition choice; user `modSettings` overrides still take precedence. Pregnant/postpartum sow pens and pens containing unweaned piglets keep Legacy feeding. Goats and Hof Bergmann's separate MILKCOW type retain their compatibility rules. The experimental Dealer v2 channel remains disabled.

## Credits & Origins

First and foremost, I would like to express my sincere gratitude to [Arrow-kb](https://github.com/Arrow-kb/FS25_RealisticLivestock), the original creator of Realistic Livestock, and [Ritter](https://github.com/rittermod/FS25_RealisticLivestockRM), who continued its development and maintenance through Realistic Livestock RM.

Their open-source contributions provide the foundation for this project, including individual animal tracking, genetics, reproduction, disease simulation, weight management, and herd automation.

This is not a standalone mod built from scratch. It is a community-developed extension of their work, with a particular focus on realistic livestock production, breed-specific performance, and agricultural economics.

## Why Hof Bergmann?

This project has been primarily developed and tested with the Hof Bergmann map.

Hof Bergmann offers a much more complete livestock production environment than most standard maps, including calf-rearing facilities, bull barns, dairy operations, slaughter facilities, meat processing, dairy production, and retail outlets.

These systems provide an excellent foundation for building a complete farm-to-market experience, from breeding and raising livestock to processing and selling the final products.

Rather than treating each animal as an isolated source of income, this project aims to connect livestock management with the wider agricultural economy.

## Key Features

### 1. Realistic Breed-Specific Growth and Production

Animal target weights, growth rates, finishing ages, and feed requirements have been rebalanced using real-world livestock production data as reference points.

Different breeds now have more meaningful distinctions. Angus, Limousin, Holstein, and Highland cattle, for example, differ in growth characteristics, feed efficiency, and their suitability for beef or dairy production.

This rebalancing currently focuses on cattle, pigs, and sheep. Horses are outside the scope of the meat-production overhaul. If the work is extended to smaller livestock in the future, the intention is to reuse simplified versions of the cattle, pig, and sheep models; no concrete development plan has been set.

### 2. More Meaningful Feeding and Fattening Decisions

Feeding strategy matters.

Grass, hay, silage, and total mixed ration (TMR) no longer produce identical growth results. Breed-specific forage efficiency also influences performance.

Players must balance feed costs, growth rates, and finishing time instead of assuming that keeping an animal longer will always be more profitable.

### 3. Reworked Slaughter and Meat Yields

Meat output is calculated using a combination of live weight, breed characteristics, slaughter maturity, finishing level, and genetic meat traits.

Carcass dressing rates, saleable meat yields, and processing costs have been recalibrated with real-world production principles in mind.

The goal is to make Hof Bergmann's public slaughterhouse and on-farm butcher follow consistent yield calculations, rather than relying on unrealistic fixed output quantities.

### 4. A More Realistic Livestock Economy

Livestock prices and processing economics have been rebalanced using the British agricultural market as a reference.

Live animal values, meat prices, slaughtering fees, processing costs, and seasonal market fluctuations are designed to work together.

Selling livestock directly, finishing animals for slaughter, and choosing the right time to market them should involve meaningful trade-offs.

Real-world prices serve as economic reference points, while adjustments are made to preserve reasonable gameplay balance within Farming Simulator 25.

### 5. Dairy Production and Breeding Economics

Milk production curves have been adjusted to better distinguish dairy breeds from beef breeds, while retaining the underlying lactation mechanics.

Additional breeding functionality allows players to collect and sell semen from their own breeding males, with its value influenced by genetics, fertility, and age.

This gives high-quality breeding stock an economic role beyond its meat value.

### 6. Deeper Hof Bergmann Integration

Animal housing rules have been adapted to reflect the intended purposes of different facilities, including calf pens, bull barns, cattle pastures, and dairy housing.

Additional integration work connects individual livestock properties with the map's slaughter and dairy systems, making its existing production chains more meaningful.

## Design Philosophy

The goal is not to reproduce every aspect of real-world agriculture with absolute precision.

Instead, this project aims to create a believable balance between realism, economic consequences, and enjoyable gameplay.

In real farming, not every animal is equally productive, not every feeding strategy is economical, and not every market decision leads to a profit.

Players should have reasons to care about the animals they raise, the feed they use, the costs they incur, and the products they ultimately sell.

Raise with purpose. Finish with care. Sell with strategy.

## Compatibility & Notes

- Primarily developed and tested with Hof Bergmann. The map is recommended for the full farm-to-market experience.
- Hof Bergmann is not included and must be downloaded separately through its [official distribution channels](https://www.lsfarming-mods.com/).
- Built upon the open-source Realistic Livestock project and Ritter's maintained version.
- Released under the GPL-3.0 license, with attribution retained for the original contributors. See [LICENSE](LICENSE); corresponding source is available in this repository.
- Version 0.2.0.0 uses `FS25_RealisticLivestockRM.zip` to preserve the tested dewar and hand-tool runtime namespace. Remove the older `FS25_RealisticLivestockF2M.zip` before installing and never load both names. Back up existing saves before upgrading.
- This introduction focuses on livestock production and economics. Broader crop and agricultural price tuning is handled separately by [FS25_EconomyTuner](https://github.com/xtcg/FS25_EconomyTuner), formerly FS25_SellPrices. Unreleased changes and validation status remain in [CHANGELOG.md](CHANGELOG.md).

## Related Mods (Optional)

These are separate projects, not bundled with Farm to Market, and are not required to use this livestock mod. Download and install them individually if you want the corresponding changes:

- **[FS25_EconomyTuner](https://github.com/xtcg/FS25_EconomyTuner)** (formerly FS25_SellPrices) — Tunes agricultural selling and buying prices, seasonal price curves, crop yields, seed usage, and shop consumable prices through configurable XML tables. It can complement the livestock and meat economy described here, but it is a separate mod rather than part of this package.
- **[FS25_ProductionInputFix](https://github.com/xtcg/FS25_ProductionInputFix)** — Fixes production points creating more output than their actual available inputs support, including cases observed with Hof Bergmann production chains. It addresses a production calculation issue independently of this livestock overhaul.

## Installation

Place `FS25_RealisticLivestockRM.zip` in your FS25 mods folder **without extracting it**, and enable it in the game. Back up your savegame before updating. Replace the existing RM archive and remove any older `FS25_RealisticLivestockF2M.zip`; do not load both names.

For inherited animal management features, compatibility details and original migration instructions, see the [upstream README](docs/UPSTREAM_README.md) and [user guide](https://xtcg.github.io/FS25_RealisticLivestockF2M/).

## Special Thanks

- Arrow-kb — Original Realistic Livestock creator.
- Ritter — Continued development, maintenance, and major system improvements.
- [Renfordt](https://github.com/renfordt/FS25_EnhancedLivestock) — Contributions to the open-source livestock disease mechanics incorporated upstream.
- LSFM / FarmerAndy — Creators of Hof Bergmann and its extensive livestock production environment.

This is an unofficial community-developed extension and is not officially affiliated with or endorsed by the original mod authors or Hof Bergmann development team.

## A Note from the Developer

You might wonder why a German map uses the British livestock market as its economic reference.

The answer is quite simple: I really enjoyed watching Clarkson's Farm. The show sparked my interest in real-world farming and inspired me to explore how realistic livestock management could work in Farming Simulator. Hof Bergmann, with its extensive livestock production chains, turned out to be the perfect place to bring these ideas to life.

This project is still evolving, and [GitHub Issues](https://github.com/xtcg/FS25_RealisticLivestockF2M/issues) are always welcome! Whether you've found a bug, have suggestions for balancing, want to share real-world farming knowledge, or have ideas for new features, I'd love to hear your feedback.

## Buy Me a Coffee

If you enjoy this mod and would like to support its continued development, you're welcome to [buy me a coffee via PayPal](https://paypal.me/XTXTCG). Thank you for your support!

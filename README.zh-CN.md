# Realistic Livestock: Farm to Market

真实畜牧：从牧场到市场

[English](README.md) · [用户指南](https://xtcg.github.io/FS25_RealisticLivestockF2M/) · [提交 Issue](https://github.com/xtcg/FS25_RealisticLivestockF2M/issues) · [下载](https://github.com/xtcg/FS25_RealisticLivestockF2M/releases)

让畜牧经营不再只是喂养动物、等待成长和出售，而是一个需要考虑品种、遗传、饲料、生产周期、加工成本和市场行情的完整经营过程。

## 致谢与项目起源

首先，衷心感谢 [Arrow-kb](https://github.com/Arrow-kb/FS25_RealisticLivestock) 创作了最初的 Realistic Livestock，以及 [Ritter](https://github.com/rittermod/FS25_RealisticLivestockRM) 在 Realistic Livestock RM 中持续进行的维护和扩展。

正是他们出色的开源工作，建立了个体动物管理、遗传、繁殖、健康、体重和自动化畜群管理等系统，才使得本项目能够在成熟的基础上继续深入。

本项目并非从零开发的独立作品，而是在上述开源项目基础上，围绕真实畜牧生产和农业经济进行的进一步扩展与重新平衡。

## 为什么选择 Hof Bergmann？

本项目主要基于 Hof Bergmann 地图进行开发和测试。

相比普通地图，Hof Bergmann 拥有更完整的畜牧设施及农产品加工产业链，包括犊牛培育、公牛饲养、奶牛养殖、屠宰加工、乳制品生产以及农场商店等终端销售渠道。

这为实现从动物出生、饲养、育肥、繁殖，到屠宰、加工和出售的完整经营循环提供了理想的基础。

因此，本项目不仅关注动物本身，还特别重视动物生产与下游产业链之间的联系。

## 核心特色

### 1. 基于真实品种的生长与生产曲线

参考现实畜牧资料，重新调整不同牛、猪、羊及其他支持动物的目标体重、生长速度、适宜出栏月龄和饲料消耗。

不同品种拥有更鲜明的生产特点。例如，安格斯、利木赞、荷斯坦和高地牛不再只是外观不同，而是在生长、饲料利用和肉用或奶用价值方面呈现差异。

### 2. 更有意义的饲料管理与育肥选择

不同饲料对动物生长效率产生不同影响。青草、干草、青贮和全混合日粮（TMR）不再具有相同的育肥效果，品种自身的饲草利用能力也会影响养殖表现。

玩家需要考虑更快的育肥速度是否值得额外的饲料投入，以及何时出售动物才能取得更合理的收益。

### 3. 重新设计的屠宰与肉品产出

肉品产量不再简单地按每头动物固定计算，而是结合活体体重、品种体型、出栏成熟度以及肉用遗传性状进行估算。

重新校准屠宰率、可售肉比例及加工费用，使 Hof Bergmann 的公共屠宰场和农场屠夫尽可能采用一致的产出逻辑。

### 4. 以现实市场为参考的经济系统

参考英国畜牧市场的价格、生产成本和产业链利润关系，重新平衡活畜买卖价格、肉品价值、屠宰费用和加工收益。

活畜价格与肉类市场建立联系，同时保留季节价格波动，使直接出售、继续育肥和送去屠宰成为真正需要权衡的经营选择，而不是无成本的套利手段。

经济参数以真实世界为参考，但仍考虑《模拟农场25》的生产规模和游戏节奏，并不追求对每项现实价格进行机械复制。

### 5. 奶牛生产与繁育经济

调整不同品种的产奶曲线，强化奶用品种与肉用品种的生产定位。

同时扩展自有种公畜的采精与销售机制，使精液价值与遗传品质、繁殖能力及年龄相关，为优秀种畜提供额外的经营价值。

### 6. 与 Hof Bergmann 畜牧设施的深度适配

针对地图内不同用途的牛舍、犊牛栏、公牛舍和草场，调整可接收动物的品种、性别及年龄规则，并改进与屠宰和奶业系统的协作。

让不同畜牧设施不再只是容量不同，而是更符合实际的生产分工。

## 项目目标

本项目希望在游戏性与拟真性之间取得平衡。

现实农业并不保证每一种养殖方式都能稳定盈利。品种选择、饲料成本、动物品质、市场行情和出售时机，都应该对农场经营产生影响。

我们的目标是让玩家不仅需要思考如何养好动物，还需要思考为什么养、养到什么时候，以及通过什么渠道出售。

## 兼容性与说明

- 主要开发及测试环境为 Hof Bergmann，完整的产业链体验建议搭配该地图。
- 本 Mod 不包含 Hof Bergmann 地图本体，地图需通过原作者的[官方渠道](https://www.lsfarming-mods.com/)单独获取。
- 本项目基于 Realistic Livestock 的开源版本继续开发，并保留原项目的核心动物管理系统。
- 采用 GPL-3.0 开源许可证。原项目及相关作者的贡献均保留署名；许可证见 [LICENSE](LICENSE)，对应源码公开于本仓库。
- 当前安装包已更名为 `FS25_RealisticLivestockF2M.zip`（原名 `FS25_RealisticLivestockRM.zip`）。FS25 会使用 ZIP 文件名识别 Mod，更名可能影响已有存档和其他 Mod 的兼容性。升级前请备份存档，不要同时启用新旧两个 ZIP。
- 本介绍主要涵盖畜牧生产与经济调整。更广泛的作物、农产品价格与投入品经济调整由独立项目 [FS25_EconomyTuner](https://github.com/xtcg/FS25_EconomyTuner)（原 FS25_SellPrices）负责。尚未发布的改动和验证状态以 [CHANGELOG.md](CHANGELOG.md) 为准。

## 相关独立 Mod（可选）

以下两个项目与本 Mod 分开发布，不包含在 Farm to Market 安装包内，也不是使用本畜牧 Mod 的必需依赖。可根据需要分别下载安装：

- **[FS25_EconomyTuner](https://github.com/xtcg/FS25_EconomyTuner)**（原 FS25_SellPrices）——通过可配置的 XML 表调整农产品卖价、买价、季节价格曲线、作物产量、种子用量及商店消耗品价格。可以与本项目的活畜及肉品经济系统配合使用，但两者是独立 Mod。
- **[FS25_ProductionInputFix](https://github.com/xtcg/FS25_ProductionInputFix)** ——修复生产设施在投入原料不足时仍可能产出超额成品的问题，涵盖 Hof Bergmann 部分生产链中出现的情况。这是独立的生产计算修复 Mod，不属于本项目内置功能。

## 安装

将 `FS25_RealisticLivestockF2M.zip` 放入 FS25 的 mods 文件夹，**无需解压**，然后在游戏中启用。更新前请备份存档，并移除旧版 `FS25_RealisticLivestockRM.zip`，不要同时加载新旧两个版本。

原有动物管理功能、兼容性及旧版迁移说明见[上游 README](docs/UPSTREAM_README.md) 和[用户指南](https://xtcg.github.io/FS25_RealisticLivestockF2M/)。

特别感谢：Arrow-kb、Ritter，以及为相关开源系统作出贡献的 [Renfordt](https://github.com/renfordt/FS25_EnhancedLivestock)。感谢 LSFM / FarmerAndy 创作 Hof Bergmann，为更深入的畜牧模拟提供了丰富的游戏环境。

这是由社区开发者制作的非官方扩展版本，与上述原作者及地图开发团队不存在官方隶属关系。

## 开发者的话

可能有人会好奇，为什么选择了一张德国地图，却采用英国畜牧市场作为经济参考？

其实原因很简单：我非常喜欢《克拉克森的农场》（Clarkson's Farm）这部纪录真人秀，它让我对真实的农业经营产生了浓厚的兴趣。Hof Bergmann 恰好拥有非常完整的畜牧产业链，因此成为了实现这些想法的理想平台。

本项目仍在持续开发和完善中。非常欢迎大家在 [GitHub 提交 Issue](https://github.com/xtcg/FS25_RealisticLivestockF2M/issues)，无论是 Bug 反馈、数值平衡建议、现实畜牧知识的补充，还是新玩法的想法，都非常欢迎交流！

## 请我喝杯咖啡

如果你喜欢这个 Mod，也愿意支持后续开发，欢迎[通过 PayPal 请我喝杯咖啡](https://paypal.me/XTXTCG)。感谢你的支持！

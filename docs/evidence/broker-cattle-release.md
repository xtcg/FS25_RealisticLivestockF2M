# Angus 断奶小牛：首批收购证据

基线为 PR #95 `a5bf1ec53e96b14d93cfb368087df630d2011b1a`，包含 #96 账本优化。对应规则 `angus-weaned:1`。完整数值、假设及源码摘要见 [JSON](broker-cattle-release.json)。这是模型和离线接线证据，实机、多人、断电均未验证。

## 条件与事实

仅开放单机、牧场接运、`COW_ANGUS/BULL_ANGUS`，沿用 `cattleWeaned`：4–10 月龄、健康至少 80、已断奶、发育月龄至少 4、未妊娠、未产奶，体重为个体年龄参考的 75%–120%。

- 断奶读取 `RLCalfRearing.getStage`；年龄读取 `RLGrowth.getContinuousAge`；发育读取保存的 `rlGrowth.developmentMonths`。
- 以实际 binding、frameTarget 和出生体重纯构建个体曲线；不调用会写活体缓存的 `getCurve`。
- 买家最低收购月龄为 4，最低体重为该个体 4 月龄参考的 75%；这是明确买家政策。
- 运行时另行检查完整身份在世界内唯一、实际圈舍成员、所有权、权限、锁和三层额度。

## 完整资格窗口

真实 FeedSim/GrowthSim、生产 Snapshot/Eligibility，默认基因，足量 FORAGE + CALFMILK、自动饮水、无疾病挑战，每月 1 个游戏日，逐小时运行 12 月。REAL 和 LEGACY 的结果相同：

| 动物 | 首次完整合格月龄 | 首次 kg | 末次月龄 | 末次 kg | 合格小时样本 |
|---|---:|---:|---:|---:|---:|
| COW_ANGUS | 4.041667 | 127.262861 | 10 | 267.697583 | 144 |
| BULL_ANGUS | 4.000000 | 142.777312 | 10 | 352.547752 | 145 |

这里完整 `eligible=true`，包括全部政策事实，区别于旧报告只有已知条件窗口。健康 79、年龄 3.99、体重 1 kg、发育不足和品种额度 0 均拒收。整段事实读取保持原生长状态不变。

复现：`tests/test_brokercattlepolicy.lua`。默认模型下可达不代表所有基因、饲料、疾病或用户覆盖配置都有同样窗口。

## 实际价格代码核算

读取真实 `getSellPrice`、购买计算和 animals.xml 运输曲线；全局 Dealer 价格仍为 legacy。买家参考为 BID 的 105%，佣金 2%，再执行 BrokerPricePolicy 限价：运输前净额不超过当前 BID，且不超过同状态当前 ASK 的 90%。接运费为普通原生运输费的 50%。没有来源奖金或任务完成奖励。

历史购入不明不被登记为自产，也不编造实际支付凭证。首版来源核验保证的是当前报价上限，不冒充完整 AcquisitionReceipt 的来源证明。有限月度需求的吸引力来自运输折扣。

HARD 样本（首个窗口的原生整数年龄为 4，母牛连续月龄为 4.041667）：

| 动物 / 整数年龄 | ASK | BID | 接运费 | 合同净收入 |
|---|---:|---:|---:|---:|
| COW_ANGUS / 4 | 697.37 | 536.44 | 30.00 | 506.44 |
| BULL_ANGUS / 4 | 706.35 | 543.35 | 38.33 | 505.02 |
| COW_ANGUS / 10 | 1393.32 | 1071.79 | 45.00 | 1026.79 |
| BULL_ANGUS / 10 | 1454.84 | 1119.11 | 65.83 | 1053.28 |

上述四组在 HARD/NORMAL/EASY 共 12 个样本均有正接运净收入，同状态购买后立即交给 Broker 均亏损。运输只扣一次，不重复乘难度。运输前收入不高于旧普通 BID，因此不额外提高旧买入→屠宰路线的商品估值。

复现：`tests/test_brokercattleeconomy.lua`。假设默认 markup 1.30、肉价参考 8.4；不是 HB 全站点、历史购入实际支出、跨难度切换或长期供需的全面经济验收。全部真实购入来源接线、来源奖励与新的繁育估值仍独立待做。

## 接线验证边界

既有 Month、Quota、OrderService、SourceAdapter、MoneyAdapter、Transaction 已由 Runtime 装配，NativeStorage、SaveAdapter、Checkpoint 已连接真实 native save hooks。联合 XML 测试覆盖初次保存、交付、保存重载、原结果查询、未保存 WAL 拒绝、最终目录重命名、sidecar 被引擎覆盖、未保存月度发布复用、不明结果随保存继续暂停。旧出售/搬运/购买、HB 交付及 Dealer v2 受同步栈和交易门控保护。

HB `1.5.0.0 Beta1` 的已审阅附加专精按安装版本、命名空间和实际模块表身份匹配，动物写入器仍须为原生模块。删除的预置建筑只作为无活体 tombstone；未知动物存储布局仍拒绝。

仍需真实 FS25 GUI、HB 活体交付、正常存档重载及故障测试。历史完整保留，受现有 portable 节点上限约束，没有宣称无限历史容量或新增自动经济恢复。

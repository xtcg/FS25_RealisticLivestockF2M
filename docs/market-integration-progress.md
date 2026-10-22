# 畜牧商人 v2 与通用市场：分步实施记录

依据：`FS25_畜牧商人v2与通用市场_整合实施设计_2026-10-22.md`，以 A–L 修订优先。开发工作树 `rlrm-market-integration`；分支 `feat/market-integration-p0`；远端更新后冻结的 baseSHA 为 `7f01d330f2de0b32a30ca8eda1ef9b1cdf4aba40`。

## 第一包：P0 / G0 起步

本包严格采用设计 J、12.6 的 U01/U02/U09/U10/U11 范围。只增加可独立测试的纯服务及冻结样本，尚未接入 `scripts/main.lua`、动物价格方法、配置加载、UI 或支付入口。运行中的游戏继续使用原实现；新服务的默认模式是 legacy。不存在本包可启用的实际 market 定价或 Broker 成交能力。

| unitId | capabilityScope | 交付 | 状态与限制 |
|---|---|---|---|
| P0 | 当前 Dealer T1–T6、身份与保存 | `market-integration-baseline.md` | 完成源码审计；已有能力与缺口分别登记；实机未验 |
| U01 | 牛猪羊健康公畜；HARD/NORMAL/EASY；单只/批量 | `tests/fixtures/market_legacy.lua`、`test_marketlegacy.lua` | 冻结旧 BID/ASK、运输费、肉量、旧屠宰保底值；基线观测与手算关系分列。不是实际路线套利扫描 |
| U02 | schema 1 的 Snapshot/ValueBreakdown/QuoteContext/MarketQuote | `RLMarketSchema.lua`、`test_marketschema.lua` | 纯形状校验；未知版本、非有限数、元表、可执行字段拒绝；缺能力与真实0区分。身份来源、指纹完整性、费用明细和有效期执行不在本单元 |
| U09 | 明确 speciesKey + breedingObjective 的注册和求值 | `RLAnimalValueProvider.lua`、`test_marketservices.lua` | 无生产 provider 自动注册；未知作用域返回 UNSUPPORTED；输入/输出复制隔离；分类/trait版本绑定；异常和重入拒绝 |
| U10 | 捕获旧 BID/ASK 的兼容包装 | `RLLegacyPriceAdapter.lua`、真实样本回归 | 原精度、当前货币、不二次加价/缩放、不加运费；保留真实0参考值而不授予成交权限 |
| U11 | 独立的 legacy/shadow/market 路由 | `RLMarketPriceService.lua`、路由回归 | 默认legacy；shadow只返回旧报价并隔离诊断异常；market必须有明确报价实现及逐scope readiness；不以Dealer READY替代 |

### 接口约定

推荐加载顺序（目前只在测试里加载）：`RLMarketSchema` → `RLAnimalValueProvider` → `RLLegacyPriceAdapter` → `RLMarketPriceService`。U12 须等 U05/U08/U11 依赖齐备后再做真实加载和退出验证。

`RLMarketSchema.validateSnapshot/validateValueBreakdown/validateQuoteContext/validateQuote` 返回 `true` 或 `false, reason`；Quote 可额外绑定 `{side, identityKey, stateRevision}`。Snapshot identityKey 是适配器提供的权威完整键字符串，校验器不生成身份、不把显示耳标转换成身份。Quote 的 `settlementDirection` 为 `IN`/`OUT`；`netToPlayer` 是带符号的玩家金额。费用/奖励本包只校验数值总额，U03 再定义统一 MoneyBreakdown 和金额一致性。

`RLAnimalValueProvider.new():register(speciesKey, objective, provider)` 使用 `COMMODITY/DAIRY/TERMINAL/MATERNAL` 的显式注册键。provider 声明 `id/version/supports/evaluate/breedingEligibility/holdingCost`，函数以普通函数调用（不是隐含 self）。`evaluate(snapshot, context)` 返回标准 ValueBreakdown 或 `nil, reason`。provider 只能消费纯数据，不得调用 `getSellPrice`、游戏全局、随机流、资金或生理推进；注册表不会向 provider 暴露活体对象，也不宣称可沙箱隔离任意恶意插件代码。

`RLLegacyPriceAdapter.new(originalBid, originalAsk):quote(side, input, context)` 返回包含 `bodyAmount/currencyBasis=CURRENT` 的参考价 envelope，**不是正式 MarketQuote 或成交凭证**。原始函数必须在未来 hook 安装前捕获。现行 `computeBuyPrice` 内部动态调用 `animal:getSellPrice()`；不得直接在新的 sell-price hook 中回调它。U10 测试用捕获的原始 BID × 现行 markup 构造旧 ASK，验证替换 live-price hook 后仍精确等价。未来生产接线须重新核查实际旧路径，不能直接假设新 ASK 也应乘 markup。

`RLMarketPriceService.new({legacy, marketQuote, pricingReady, observe})` 提供 `setMode/getMode/quote`。市场回调接收 `side/snapshot/context`，结果必须通过 schema、请求方向、身份、状态和版本绑定。缺少 readiness 或返回非 true 时拒绝 market 输出；坏模式配置切回 legacy。该层没有权限、凭证和恢复放行权；发生真实交易恢复问题时，不得借模式回退绕开未决证据。实际 readiness 和 marketQuote 尚未实现，仅以注入夹具验证路由。

### Code review

由独立 subagent 审查 schema、provider、legacy 包装、路由与测试。确认并修复两个 P2：

1. 协议校验在拒绝元表前执行 `__index/__pairs`：现在在任何字段读取/遍历前拒绝根表和嵌套元表；测试确认 getter 没有执行且不外抛。
2. 直接使用 provider 注册表时，snapshot/context 分类及 trait 版本错配仍可估值：现在在调用 provider 前返回 `SNAPSHOT_VERSION_MISMATCH`，有反例测试。

没有把既有身份自动修复、WAL 归档及保存绑定缺口混入本包修复；这些列于基线审计，按后续 P2/P4 处理。

### 验证记录

implementationSHA：`aa15046511f099f6afcd0a0cd25c9a5cd96109db`。configRevision：U01 fixture revision 1；纯协议 schemaVersion 1；其余采用 baseSHA 内有效配置。runtimeMode：生产 legacy；shadow/market 仅注入测试。map&gameVersion：离线 stub，未实机/联机。

| checkType | commandOrSavegame | expected / actual | status / blocker |
|---|---|---|---|
| 定向协议/路由/旧行为 | `python3 -c 'import sys; sys.path.insert(0,"tests"); import run; paths=["tests/test_marketschema.lua","tests/test_marketservices.lua","tests/test_marketlegacy.lua"]; results=[(p,run.run(p)) for p in paths]; print([(p,len(r),[n for n,ok in r if not ok]) for p,r in results]); sys.exit(any(not ok for p,r in results for n,ok in r))'` | 86 + 25 + 41 = 152 / 152通过 | PASS；lupa 2.8 默认 Lua 5.5 |
| Lua 5.4 兼容 | 上述命令 import run 后增加 `from lupa.lua54 import LuaRuntime; import lupa; lupa.LuaRuntime=LuaRuntime` | 同一152项 / 152通过 | PASS |
| Dealer分析器 | `python3 tests/test_dealer_v2_analyzer.py` | 15 / 15通过 | PASS |
| 全量Lua回归 | `python3 tests/run.py > /private/tmp/rlrm-market-final-tests.log` | 全部通过 / 5286/5286通过，exit 0 | PASS；获准在沙箱外执行 |
| 独立review复现 | 元表伪造snapshot；分类/trait版本错配provider | getter调用0次；provider调用0次 / 均满足 | PASS；独立复查2/2 |
| 差异格式 | `git diff --cached --check`、`git diff --check` | 无错误 / 无输出 | PASS |

全量 `python3 tests/run.py` 初次在既有 `test_dealerstock.lua` 的 `/var/tmp` 临时文件创建处受沙箱阻挡退出，不记为测试通过或代码回归。获准在沙箱外重跑后最终5286/5286通过。定向152项属于这次全量集合，不与5286相加；Lua 5.4仅重跑定向集合，未声称全量5.4通过。未进行实际价格校准或游戏内测试。

## 后续顺序

1. P1 / G0：U03 MoneyPolicy；U04/U05 配置解析；U06 曲线月历；U07/U08 只读物种映射及快照；依赖齐备后 U12 加载关闭框架。金额量化须先验证引擎有效精度，不先假定0.01。
2. P1 / G1：按真实能力实现 U13–U19、U25–U32。只做 shadow，先完成 S 与独立 ASK/BID 的同basis明细和经济反例。
3. P2 可与纯价格工作独立推进：复用身份分配，补同步烧号、统一 AcquisitionReceipt、资源排序锁及共同保存证据。较弱历史迁移保证不自动接受。
4. P3/P4：补库存退出、持久生成任务及购买新ASK/来源凭证接线；保持v2严格报价复验；牛类单机及地图/容器实测通过后才开放对应能力。
5. P5–P8：Broker条件包、月度需求及三层额度只读闭环，再按接运/自送、物种、地图、单机/联机分别通过真实交易和经济验收。

完整设计尚未完成；本包不把后续单元或新价格启用关卡标为通过。

## 持续开发：2026-10-23

用户已要求持续执行直至全部完成。仓库内保存了输入设计的原文快照：[整合设计](market-integration-design.md)；其“本次未实施”等描述属于原稿状态，当前实施以本文件和 [96单元跟踪](market-integration-units.md) 为准。

### 已提交的增量

| implementationSHA | 结果 | 验证与开放边界 |
|---|---|---|
| `23273629` | U04–U08 配置/曲线/真实快照；U03 默认原精度金额；U13/U14 独立屠宰净收入及明确站点basis；U19/U26–U30 虚拟成本/等待期/独立ASK/BID；U12关闭模式装载 | 配置70、曲线30、快照39、金额14、数学19、屠宰15、装载22项定向通过。U12仅离线装载顺序/lifecycle夹具，实机载入退出未验；U03候选量化尚无真实资金/网络/保存roundtrip证据，默认不量化。现有报价仍legacy |
| `40b1787c` | P2身份同步日志与启动身份边界；WAL精确归档 | 分配/整胎/Dealer预留先双槽完整日志回读再曝光；坏槽、未完成startup检查、未知旧代日志不能被live scan洗清。去掉启动自动重编号，保留历史ID并关闭检测到冲突的T02/Dealer门控。当前纯层离线完成，不把物理fsync/断电原子性或共同存档代次绑定标完成 |

独立review发现并修复：decimal网格误降/大金额误抬、肉量计算先算后验异常、稀疏用途数组静默丢项、同品种母畜遍历顺序影响快照、日志重入丢烧号、startup恢复早退跳过日志、稀疏journal keys被忽略、T02只记录身份冲突但未关门。均补了能复现原问题的反例。

### 开发中但尚未开放的模块

Broker具备15种候选条件包、完整拒收/未知能力结果、固定六组选择指数、三层额度纯账本及旧月未决成功恢复边。编译包不等同U51模型可达性。Review修复了固定指数被自定义权重绕过、泌乳包接受BEEF、跨物种SPECIFIC键和商品包伪精英tier；条件包101项、资格94项定向已建立，后续仍逐包独立复验。

购入来源纯账本支持schema2原子recordBatch、同一真实purchaseRequestId的逐头实际支出、批次费用总额、持久幂等和严格恢复（76项）。目前未把所有实际购入/出生路径和共同保存接入，所以U66不能标为贯通。未记录来源不会被认作自产；所有来源豁免先绑定同一animalKey。

Broker纯价格遵守奖金先限价、成品S差额、当前货币来源支出和统一运输前净额；正式单只凭证按15秒真实单调时间、每调用者仅一个待确认凭证，并绑定发布月、完整结算明细和版本。复验接受仍合格且全部金额/费用不变的微变，不能把此策略套入Dealer严格报价。交易协调器和实际UI/网络尚在开发，凭证服务不能移除动物或支付。

牛猪羊原始生产参考、实际只读参数适配、月需求与持久发布生命周期、单只来源/资金适配正在开发及交叉review；专用成本/退出/配种规模/后代净值等缺失时保持unsupported。测试目录使用testOnly可达性证据，默认不能作为生产发布目录。

### 本轮验证证据

完整 `python3 tests/run.py` 在获准的沙箱外运行返回 **5792/5792、exit 0**，日志 `/private/tmp/rlrm-market-phase2-tests.log`。执行期间新功能并行开发，这个数字只证明当次实际枚举/读取的测试集合，不当作随后新增provider/凭证/批次凭证改动的全部验收；后续增量另做定向记录，最终集成再统一跑冻结版本。

身份修复后定向：checkpoint90、runtime65、entries19、Dealer runtime35；新增历史身份冲突门控后：真实磁盘 `test_trade_persistence.lua` **164/164**、Dealer checkpoint27、startup3。Trade磁盘回归按已有权限流程单独升级，未绕过sandbox。Dealer正常流程和遗留报告中的“成功修复”统计保留原语义，新冲突使用单独identityConflicts字段。

尚未执行实机、双客户端、真实地图接收点、完整共同保存中断或实际经济发布校准。所有新能力仍受独立门控关闭；本目标保持进行中。

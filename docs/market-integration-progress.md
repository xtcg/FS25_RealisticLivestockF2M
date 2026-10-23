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

## Broker 协调与报价编排增量

本阶段已提交以下开发包，继续沿用独立 worktree；未触碰主工作目录内用户的未提交修改。

| implementationSHA | 实现 | 证据及限制 |
|---|---|---|
| `73457827` | 分物种生产参考、15 种条件包、月需求与持久发布、三层额度、批次购入来源、报价凭证、来源与资金适配 | 17 组定向共 542 项通过，并完成独立 review。购入来源现为 80 项，包含实际支付顺序浮点累计与重排幂等；并非所有真实购入路径已接线 |
| `4e5c5d62` | 有限公开买家只读 shadow 诊断；真实生理测量工具与报告 | PublicRoute 13 项通过；true 开关拒绝，有限买家不改变 actualDealerBid，不预占额度。28 个 36 月牛场景、84 组包测量，完整资格通过 0；[完整报告](evidence/market-cattle-physiology-36m.md) 不作为 U51 准入目录 |
| `a1c7298e` | Broker 单只事务协调器、专用双槽持久层、共同保存证明与恢复桥接 | Transaction 50、Persistence 30、Checkpoint 51 项通过；共同证明检查整份文档，不凭 requestId 或 bool 认定历史结清。全部为注入式引擎适配组合，尚未接 main、真实 XML 存储和同步保存 hooks |
| `f1cf19e1` | 全用途 provider → 独立 ASK/BID → MoneyBreakdown → 统一 Quote；纠正共享 retailBase 的转售价 A | DealerQuote 23、MarketMath 20 项通过并独立复验。未实现目标显式排除；已有合法目标缺经济参数则拒绝整对报价，不以低商品 ASK 代替。新价格仍未接真实买卖事件 |

独立 review 修复了最终 ready/saveFence 回调跨过凭证 TTL、迟到 source/money 持久回调覆盖终态、数值 1/1.0 钱包锁键不同、持久存储同步重入、弱 checksum 被当完整幂等相等、保存验证期间旧 READY/恢复证明仍可用、失败 freeze 被当成功、整份事务文档共同保存证明缺桥接，以及禁售动物仍取得新报价等反例。

事务未知结果保留动物/钱包/容器及原月三层额度锁；无自动退款、无重建新动物、无付款重放。历史长期累计仍受 portable 数据节点上限约束，生产接线前需实现保留幂等证据的分片/归档，不声称无限历史容量。资金实际精度与物理同步落盘能力仍待实机验证。

下一步继续真实持久存储与同步保存适配、旧价格消费者/购买事件及全部来源路径接线，并补各发布 scope 的完整事实配置、可达性与价格全链扫描；UI、网络接运/自送和实机/联机验收仍属于完整目标，不能由本阶段纯服务测试代替。

冻结代码 `f1cf19e1` 的全量 `python3 tests/run.py` 返回 **6272/6272、exit 0**，日志 `/private/tmp/rlrm-market-phase3-tests.log`。运行期间 Lua 源码与测试保持冻结，仅提交相同代码及更新实施记录；此结果覆盖上述 pure 模块、既有完整回归，不覆盖其后新增 native XML 或 main 装载改动。既有磁盘测试按权限流程在沙箱外执行，没有绕过沙箱。

随后新增 `RLBrokerNativeStorage`：使用实际 FS25 `XMLFile.create/loadIfExists/save/getAsString/delete` API 形状，完整验证 serializer 返回的全部树结构，允许声明、缩进及属性换序等格式差异，再规范化为专用 codec 的完整逻辑串，继续用双槽精确回读。不会以 `io.open` 读取游戏文件。68 项定向覆盖三道 barrier、假成功写盘、重复/未知字段、旧证据、混代及清理/重入故障；这是内存 native API 夹具，不冒充真实游戏持久化证据。引擎 XML parser 在返回树之前已丢弃的原始词法信息无法恢复，适配不声称原始字节验证或物理 fsync。

已复查的纯定义和 native 工厂加入 main 装载顺序；启动测试读取实际 main 列表逐个加载，验证 provider/订单/付款服务没有自动启动，未替换 `Animal.getSellPrice`，三种准入 gate 仍关闭。市场运行时仍保持 legacy，实际 store、同步保存 hooks、真实价格绑定和 UI/网络尚未装配。

## 既有价格入口与原生共同保存适配

| implementationSHA | 实现 | 验证与未完成边界 |
|---|---|---|
| `6ad94a2f` | `RLMarketSaveAdapter` 为共同 checkpoint 提供真实 XMLFile 读写、native marker、career proof、四类实际 payload validator 和双槽跨代档案 | 定向59项。动物角色是每次从 placeables/vehicles 全文派生的 manifest，不虚构 animals.xml。当前动物键读取器仍需注入真实 inspector，缺失明确 unsupported；没有安装实际 save hooks |
| `b9297ff1` | `Animal:getSellPrice` 与单只/批量购买经统一模式路由；旧公式独立为 `getLegacySellPrice`；自动管理员经 day-tick 注入独立 ASK/BID；购买 UI 与服务端金额复核 | Engine31、BuyUI10、Construction79、Legacy41、AI115、live sale154、Birth40、DealerQuote23、装载50项定向通过并独立review。生产 bind 仍强制独立 Runtime 门控；目前没有准入 scope 或真实经济参数装配 |

购买事件服务端分别重算本体和实际运输腿（拖车为0），拒绝不可报价、非有限/负数、错误符号、伪造分量及相同总额下换费用分配；仅允许 float32 wire 表示误差，实际收支保留服务器 double。报价失效使用4bit协议中新增code9，17种语言各有一个 priceUnavailable 文本；选择中任一只不可报价时整份购物车不返回部分总额，不弹确认框，不当作免费动物。普通库存来源规范化、旧wire重放幂等和实际购入凭证仍未全部贯通，U36不能据此整项验收。

Review追加并关闭了错误难度/参考载荷的缓存报价可被接纳、监控面板对nil价格做除法、出生已写身份亲缘后因nil报价排序失败的反例。Quote scope绑定完整referenceInputs及难度、参考版本、日历/绝对时间；已准入 scope 中报价失败不切回另一价格，未准入 scope 明确保留legacy，shadow错误不改变现金。强制病畜淘汰与出生满栏处置保留明确的旧补偿/处置依据，不反调可拒绝的live BID；这两条出口仍须纳入跨渠道经济扫描，未声称已校准或迁移为普通Dealer交易。

已吸收的身份分配日志不要求删除：适配实际读取原身份owner XML、原career身份marker及四个原生参与文件，验证其独立身份代次、共同sharedSaveId、全文与完整导出ledger一致；旧日志只有sequence与所有key已被该保存账本吸收且main/pending完整一致，才可加入共同证明。同代/未来代、缺键、序列超前、异谱系或未知残留仍拒绝。不会用市场generation代替独立身份generation，也不会凭live scan清除日志。

冻结代码 `b9297ff1` 的完整回归返回 **6488/6488、exit 0**，日志 `/private/tmp/rlrm-market-phase4-tests.log`；运行期间源代码/测试未改动，仅提交相同代码。实机、地图GUI、双客户端及断电持久性仍未验证。此结果不自动覆盖其后缓存/默认native inspector等新增改动。

## 收尾：默认原生动物清单读取器

| implementationSHA | 实现 | 验证与未完成边界 |
|---|---|---|
| （本提交） | `RLMarketNativeAnimals`：从原生 `placeables.xml`/`vehicles.xml` 全树只读列出逐头动物键（farmId + id + 出生国），供 `RLMarketSaveAdapter.inspectAnimals` 注入；`fromMission` 以世界中实际对象的 UID、写入专精模块、所有者和持久化状态决定每个容器 | 定向24项（`test_marketnativeanimals`）；装载顺序与 main 全列表装载通过；全量 **6518/6518** |

上一阶段留下的未提交草稿有两处会让真实存档整体判为 unsupported，已修正：

1. **精液管的种公记录。** `DewarData`（车辆）与 `DewarObjectStorageHook`（物品存储）把种公写为 `dewarData` 下名为 `animal` 的记录（带 `genetics` 子节点、无 `numAnimals`）。草稿把它当作未声明的活体布局拒绝；现在单独计为 `strawRecords`，不进入活体清单。`dewarData` 下带 `numAnimals` 的节点、或记录内部再嵌套的 `animal` 仍拒绝。
2. **地图/模组对象。** 草稿要求 `customEnvironment==nil`，Hof Bergmann 的栏舍来自地图模组，世界里任一模组车辆也会让整份清单失败。现在以写入专精模块的身份（`PlaceableHusbandryAnimals`、`LivestockTrailer` 原模块）为准，不看对象来源；名称表明可能存动物的模组专精（含 animal/livestock/husbandry/horse/rideable）仍拒绝，其他模组对象视为 NON_ANIMAL。

真实存档只读核对（离线，按文档自身布局解析容器，不经世界对象）：

| 存档 | 地图 | placeables 活体 | vehicles 活体 | 精液管记录 |
|---|---|---:|---:|---:|
| savegame2 | Hof Bergmann | 16 | 4 | 2 |
| savegame3 | Le Mechet | 45 | 0 | 0 |
| savegame4 | Hof Bergmann | 52 | 38 | 2 |

数量与文件内 `<animal` 计数逐一吻合。这只证明文档布局可读；`fromMission` 对真实世界对象（HB 栏舍专精列表、模组车辆）的判定尚未实机验证，若 HB 栏舍带名称含 husbandry 的地图专精，会明确返回 unsupported 而非误读。SaveAdapter 仍未在生产中实例化，同步保存 hooks 未安装，市场运行时保持 legacy。

## 本阶段收尾状态

- 分支 `feat/market-integration-p0`（基于 `dev@7f01d330`），全部改动已提交；全量回归 6518/6518。
- 所有新能力仍由独立门控关闭：生产价格模式 legacy，无准入 scope，Broker 交易/保存 hooks/UI/网络未接线。合入 `dev` 不改变玩家可见价格与交易。
- 未完成且不得据本阶段标为通过：真实保存 hooks 与 SaveAdapter 装配、各发布 scope 的经济参数与可达性扫描、UI/网络接运自送、实机/联机/断电持久性验证（见单元表）。

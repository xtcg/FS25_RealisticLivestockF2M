# 畜牧商人 v2 与通用市场：分步实施记录

## 2026-10-25：基于 PR #95 的首个可玩范围

当前增量见 [玩家入口](broker-playable.md) 与 [完整资格/经济证据](evidence/broker-cattle-release.md)。以下范围状态替代历史记录中的“Broker 全部未接线”：单机 Angus 断奶小牛、月度共享额度、牧场接运、逐只确认及 native 共同保存已完成代码接线，首次完整保存后开放；联合 XML/事务/UI 回调离线回归已增加。全局 Market 定价、自送、猪羊和多人继续关闭。

同时修复正常成交 staged/live quota 证明不一致，增加保存前完整文档递增/回读屏障、sidecar 覆盖前快照、最终目录 store 重绑、未保存月度需求复用和不明结果随保存携带。Broker 与旧交易入口双向执行栈门控；保存时排除未售商人库存，避免反复导入永久身份账本。HB Beta1 companion 按版本及模块身份授权。

不把 U88/U89 实机/联机验收标为完成。安装包为 `0.2.2.0` 候选版，未发布 release，未合并 PR #95。

最终验证：冻结源码的 `python3 tests/run.py` **7148/7148、exit 0**，日志 `/private/tmp/rlrm-broker-frozen.log`。Lua 5.4 定向 **702/702**（新 Broker、联合保存、UI、身份与相关既有交易）；27 个 Broker/保存/身份/菜单模块通过 Lua 5.1 编译。`tests/check_structure.py` 为 399 文件、396 个文件级全局、0 问题，`git diff --check` 通过。现有磁盘回归使用已授权的沙箱外执行；不把先前 `/var/tmp` 受阻的那次运行算作通过。

依据：`FS25_畜牧商人v2与通用市场_整合实施设计_2026-10-22.md`，以 A–L 修订优先。开发工作树 `rlrm-market-integration`；分支 `feat/market-integration-p0`；远端更新后冻结的 baseSHA 为 `7f01d330f2de0b32a30ca8eda1ef9b1cdf4aba40`。

## 第一包：P0 / G0 起步

本包严格采用设计 J、12.6 的 U01/U02/U09/U10/U11 范围。只增加可独立测试的纯服务及冻结样本，尚未接入 `scripts/main.lua`、动物价格方法、配置加载、UI 或支付入口。运行中的游戏继续使用原实现；新服务的默认模式是 legacy。不存在本包可启用的实际 market 定价或 Broker 成交能力。

| unitId | capabilityScope | 交付 | 状态与限制 |
|---|---|---|---|
| P0 | 当前 Dealer T1–T6、身份与保存 | `market-integration-baseline.md` | 完成源码审计；已有能力与缺口分别登记；实机未验 |
| U01 | 牛猪羊健康公畜；HARD/NORMAL/EASY；单只/批量 | `tests/fixtures/market_legacy.lua`、`test_marketlegacy.lua` | 冻结旧 BID/ASK、运输费、肉量、旧屠宰保底值；基线观测与手算关系分列。不是实际路线套利扫描。修订 2（2026-10-23）：合入 #87 后猪羊有体况，重新录制猪羊值，牛不变 |
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


## 收购合同前置框架重构（2026-10-24）

基于 `dev@15ac4a19`。本批集中可共享的协议与测试基础，不开放任何 market/Broker 准入 scope。

- `RLSpeciesCatalog` 集中 COW/PIG/SHEEP/GOAT/MILKCOW 的引擎类型、营养分段、曲线类型/绑定、泌乳语义、市场模型与选择指数前缀，以及15类 Broker 包的物种/用途/年龄健康边界。配置分段、市场分类的物种解析、provider 注册及合同包编译消费此表。成员表不是能力认证：GOAT 不借用 SHEEP provider，MILKCOW 继续不进入市场；实际品种的生产类别仍以 Dealer/市场配置解析为准，泌乳输出仍读取真实 subtype。
- 共用市场契约测试按成员表运行，覆盖确定性、无输入修改、未知成本、不育/阉割/退出年龄及跨物种隔离；专项现金流数值测试继续保留。配置一致性测试读取真实 feed/body/weight 解析器，并逐个编译成员表中的合同包。15包在普通/慢熟设置下的30份规范输出与重构前完全一致。
- PigSim/SheepSim 共享类型查找和食物组构建；猪羊校准器与测试入口共享 Lua 启动和结果转换。日粮、繁殖季节、模型、科学参考和判定阈值仍分别维护，没有机械合并不同生理。
- `RLAnimalState` 统一 Broker 来源与 Dealer 目标的业务状态边界，排除带回指的视觉对象和引擎定位字段，保留完整妊娠、疾病和生长数据。嵌套方法的兼容策略由渠道显式指定。Broker 接受真实圈舍字符串引擎ID，也允许未生成视觉ID的成员；锁和成交身份仍使用完整动物键。
- 新来源证据版本2以完整规范状态字符串保存各成员的比较证据（不是短哈希），选中动物仍保存完整业务树；验证器保留版本1读取。`RLMarketData.copy` 改为校验与复制一次遍历，不再为每次复制生成规范字符串，节点/深度限制和隔离语义保留。新增60头圈舍连续30次交付的回归；此结果不是无限历史容量证明。
- 报价拒绝分支保留第三返回值的资格详情，避免UI重新请求诊断。

后续随实际收购闭环继续实施：运行时装配；跨旧渠道的共同资源锁准入；引擎保存生命周期协调；共同保存后的历史分片/归档。当前精简证据降低了节点占用，但全历史仍有容量限制与全量读写成本；不能通过删回执、增大常量或短哈希冒充已完成归档。市场能力门仍关闭。新增物种复用已有模型时可集中登记；新生理、地图容器和引擎接入仍须能力与实机验证。


本批验证（业务代码 `ae7d0cc1`）：完整 `python3 -B tests/run.py` **6884/6884，exit 0**（lupa Lua 5.5，日志 `/private/tmp/fs25-framework-tests.log`）；Lua 5.4 下16个相关文件 **521/521**；12个新增/修改业务 Lua 文件通过 Lua 5.1 语法编译；15个合同包普通/慢熟30份规范结果与原实现完全相等；共享校准启动器与嵌套结果转换核对通过。完整测试首轮在旧测试写 `/var/tmp` 时受沙箱阻挡，按权限流程重跑后通过。未执行实机、联机或完整科学校准，不把成员一致性检查当作新物种流程认证。


## 全项目共用边界整理（2026-10-24，续）

继续在前置框架基础上整理实际运行的跨模块流程：

- `RLNativeSaveHooks` 统一原生保存方法的挂接入口。Trade、Dealer、Identity 按原注册顺序加入；前置回调逆序、后置回调顺序，保持原 Utils 包装行为。三个 checkpoint 仍各自负责错误保护、完成目录取值、标记、代次、文件格式和恢复判定，注册器不产生共同保存证明。重复安装不重复包装；回调内拒绝新增监听；测试的独立引擎世界创建独立注册器。
- `AnimalProduction` 接管逐小时输入/产出计算，Animal 保留原方法委托、可配置类字段和持久字段。输入计算与提取前逐字一致；输出只将曲线读取交给共用读取器，其余哺乳、胎次、疾病、体况及精液规则保留。
- `RLAnimalOutput` 为产出计算、饲料成熟奶量预测、Dealer回放与市场快照提供同一个曲线形状读取边界。兼容直接 AnimCurve 与原生 `{fillType, curve}`，奶罐回退及精液排除继续沿现有 Animal 判定。修复 feed 成熟奶量只识别直接 `.get` 的遗漏：同一原生包装曲线在旧入口读成0，新入口与Dealer一致读为120（固定探针值，不是生产参数）。
- 新增原生保存监听顺序/签名/重入/异常测试，并通过三个真实 checkpoint 安装器的组合检查；新增成熟奶量与商人读取一致性测试。未改存档schema、网络协议、经济参数或准入开关。

全项目检查中暂不机械合并：RealisticLivestock.lua 带执行告警的历史兼容路径；不同语义的浅复制/纯数据复制/动物业务状态复制；Feed 内有共享局部状态的营养计划和资源结算。它们需要按调用与恢复契约继续拆分，不能仅按物种字面量数量或重复行数批量替换。本批保存入口整理不等于Broker运行时、统一冻结或历史归档已经贯通；新增模块未授予这些能力。


本续批验证：完整 `python3 -B tests/run.py` **6904/6904，exit 0**（Lua 5.5，日志 `/private/tmp/fs25-project-framework-tests.log`）；Lua 5.4 下11个相关测试文件 **390/390**；10个新增/修改模块通过 Lua 5.1 语法编译（Animal 主文件保留既有 GIANTS `continue`，其委托由专项和完整回归执行）。新原生保存监听测试共13项，包含三个真实安装器组合、目录优先级及观察器异常。没有执行游戏内或联机保存验证。


## 共享数据原语与静态结构检查（2026-10-25）

基于上一节的分支，合入 `dev@09c1db03`（PR #96，无冲突，合并后回归 6930/6930）后继续。

- **`RLPlain`**（`scripts/core/RLPlain.lua`，`main.lua` 第2b节最先加载）收口 dealer / market / 交易账本各文件私有定义的同形函数：`copy`（无环保护的递归复制）、`equal`（结构相等）、`finite`、`text`（含非空白字符的字符串）、`dense`（键恰为 1..#t）。只收录各处**逐字等价**的实现：改写按“归一化函数体（变量名、分号、空白无关）完全一致”机械匹配，共替换 93 处定义（60 个文件）；带校验的复制（`RLMarketData.copy`、`RLTradePersistence.parse`）、带上限的协议检查（`RLDealerPurchaseProtocol` 的 `dense/text`）、基于规范串的 `equal`、带环检测的 `RLDealerListingRegistry.copy`、剔除 `ref` 的 `RLHBContractAdapter.copy` 语义不同，原样保留。`RLMarketSchema` 因其测试要求仅凭 Lua 原语即可加载（证明线协议不依赖 mod 全局），保留私有副本。事件层（MP）、feed/growth 纯模型层不在本批范围。
- **`tests/check_structure.py`**（由 `tests/run.py` 调用，CI 的 `python tests/run.py` 即带上它）：
  1. 加载顺序：解析 `main.lua` 的 `source` 顺序，找出每个文件在**文件作用域**（函数体之外）读取、而由**更晚**加载的文件赋值的全局。此前 `main.lua` 里十余处“必须排在 X 之后”只写在注释里，只有实机加载才暴露。自检：把 5 组注释已声明的依赖对（RLDiseaseRecord→RLDiseaseDefinition、RLDealerQualityModel→Resolver、RLConstants→RLGenetics、RLHerdsmanRuleService→Presenter、RLMenuTabPolicy→RLMenu）互换，必须报违规，否则判定扫描失明。当前真实顺序 0 违规；把 `RLPlain` 挪到最后会报 60 处。
  2. 全局冲突：两个文件对同一全局赋值（非 `X = X or ...` 幂等形式）会按加载顺序静默覆盖；当前 0 处。
  3. 私有副本：dealer / market / animal 内不得再出现与 `RLPlain` 等价的文件作用域私有定义（含 `isFinite` 写法），例外清单写在检查器里并注明原因。
- **`AnimalProduction.updateOutput`**：曲线不可读（`RLAnimalOutput.curve` 返回 nil）的输出原先在逐小时更新中直接索引 nil 报错，其后的 nil 保护与告警成了死代码；现按该保护的原意产出 0 并告警，不中断同一动物其余输出。新增 2 项测试。
- 新增 `tests/test_plain.lua`（19 项：NaN/无穷、共享子表独立复制、元表丢弃、额外键双向、空洞/字符串/小数/零负键）。

验证：完整 `python3 -B tests/run.py` **6952/6952，exit 0**（Lua 5.5）；`economics.py` 可运行；`marketreachability.py --months 2 --subtype COW_HEREFORD` 在改动前后输出逐项一致（仅 `sourceSha256` 元数据不同）。未做实机、联机验证；本批不改存档 schema、网络协议、经济参数或准入开关。

仍未收口（需按调用与恢复契约分别处理，不能按行数批量替换）：6 个 MP 事件各自的 `getUserContext` 与“权限 + 农场作用域”校验；`integer` 的 17 种带不同上下界的变体；`fail/call/fields/keys` 的不同错误返回约定；`AnimalProduction.updateOutput`（175 行）按产出类型拆分。



## 生命周期、依赖缓存与事件作用域（2026-10-25）

在用户修改后的 `4e673c82` 上继续。读取并进行结构扫描的范围为 `scripts` 下398个Lua模块、125920行、27个顶层区域（含main.lua）；据此深读客户端请求、配置事件、饲料信息、繁育配对、保存、消息和运行时缓存等调用链。完整源码结构检查仍覆盖main.lua实际加载的394个文件，本批0违规。

本批选择可直接复现的状态错误，而非继续机械抽取函数：

- **客户端请求拥有自己的资源生命周期。** `RLAnimalEventRequest` 的 token 持有取消操作；reset/loadMap/deleteMap逐个静默取消订阅与watchdog，再放开新会话请求。清理操作各自隔离异常，遗留计时器/订阅即使被引擎再次调用也不能再次消费旧请求。回调必须是函数；同步超时不会继续发送，同步回复已经完成后send再抛错不会让调用者误以为整次请求未被接纳。保留同事件类单请求门控和原超时协议；这里不撤回服务端操作，也不新增wire requestId或宣称解决所有无关联ID的迟到响应。
- **饲料显示缓存按依赖失效。** 原先只比较tick和总量（还保留三位小数），等量换料、草场可用量和容量变化可能继续显示旧行。现在比较各支持fillType的槽内/可用库存、容量、月份小时及相关数据/配置对象；未变时仍复用同一行数组。测试包含真实总量计算下的900/1100替换1000/1000，不强制清缓存或改动营养计算。
- **配对缓存按注册表与对象作用域。** `RLBreedingValue.getCounterpart` 不再以显示名称作为唯一键，不缓存加载期的未找到结果；按当前AnimalSystem、subTypes容器、来源subtype对象和性别缓存，命中前验证原注册表槽位和类别仍一致。世界引用使用弱值，来源对象使用弱键，不把旧动物系统留在内存里。此处没有改动PV或经济公式，也没有宣称重构了整个报价缓存。
- **六个远端配置事件共用农场边界。** 过滤器与Herdsman规则的create/update/delete复用`RLPermissionHelper`用户和农场解析，作用域检查都拒绝无效农场，即便请求者与记录都写成0或1.5。保留已有nil-farm全局过滤器政策、存储版本/农场防篡改和广播顺序；客户端不能提供解析上下文，服务器仍实时读取权限和归属。

新增回归87项（请求14、配对10、饲料缓存6、事件作用域57）。将新探针在内存中切回基线实现：配对7项、饲料缓存5项、作用域13项失败；请求清理也出现失败及stop异常。这些比较没有替换工作树文件。已有行情、存档schema、网络格式与收购能力门不变。尚未游戏内/联机验证。


验证：完整 `python3 -B tests/run.py` **7039/7039，exit 0**（Lua 5.5，含结构检查，日志 `/private/tmp/fs25-framework-lifecycle-tests.log`）；Lua 5.4下9个相关文件 **342/342**；10个修改业务Lua文件通过Lua 5.1语法编译；`git diff --check`通过。保留用户上一批RLPlain、结构检查和PR #96的清理成果，没有修改主工作目录中未提交的手册/UI内容。

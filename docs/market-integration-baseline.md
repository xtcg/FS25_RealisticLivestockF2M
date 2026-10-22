# 市场整合 P0：Dealer、身份与恢复证据基线

审计日期：2026-10-22。baseSHA：`7f01d330f2de0b32a30ca8eda1ef9b1cdf4aba40`（简写 `7f01d33`）。依据：仓库外《FS25_畜牧商人v2与通用市场_整合实施设计_2026-10-22.md》A–L、附录二；本文件只记录基线，不授权启用渠道或放宽迁移保证。

本文件记录源码、现有测试和文档的只读审计，未运行游戏、未安装包、未改存档；审计阶段未重新运行测试，随后开发验证结果另见 `market-integration-progress.md`。表中的测试名表示存在可复用的测试入口，**不表示该项能力已经通过本次完整验收**。历史文档中的 4128/4128 等结果不能用作本次实施的通过记录。基线本身没有 implementationSHA；configRevision 为基线提交内配置；实际地图、游戏版本与部署包摘要尚未取证。

状态用语：**代码已有待核验**＝读到实现和/或测试；**需修改**＝与整合契约有明确差距；**待实现**＝未找到对应新能力；**缺能力**＝该运行作用域目前不可开放；**实机待验**＝需引擎/地图/联机证据。没有将“文件存在”登记成“可复用已核验”。

## 运行开关与作用域

| 项目 | 基线证据 | 状态与边界 |
|---|---|---|
| Dealer v2 默认 | `scripts/dealer/RLDealerRuntime.lua:3`、`reset` 每次置 `CHANNEL_ENABLED=false`，载入后 DORMANT；`enable` 才装 service/events | 代码已有待核验；保留默认关闭 |
| Dealer 开放条件 | `RLDealerRuntime.gate/enable`：身份 authoritative、checkpoint READY、服务安装、`cattleSingleplayer`；多人返回 `MULTIPLAYER_NOT_VERIFIED` | 牛类单机测试入口已有；羊/猪、多人、具体地图/容器缺能力或实机待验。`enable` 自行设置 cattleSingleplayer=true，不能据其名称认定已有实机认证 |
| 身份模式 | `scripts/animal/RLAnimalIdentityRuntime.lua:58` 默认 SHADOW；OFF/SHADOW/ON，`activate` 要求扫描与迁移证明，MIGRATION_POINT 需显式 accept | 代码已有待核验；本次不接受较弱迁移、不切 ON |
| 价格模式 | `RLDealerAssembly.lua:39` 默认调用 `RLAnimalBuyService.computeBuyPrice`；该服务沿 `getSellPrice()*markup` | 当前 legacy 路径。整合的 legacy/shadow/market、独立 market ASK 尚待实现；旧市场相关函数名不能视作统一价格层 |
| 独立能力门 | 未找到整合契约的 `marketPricingReady(scope)`、`brokerPreviewReady(scope)`、`brokerSettlementReady(scope, mode)` | 待实现；不能用 Dealer READY 替代价格或 Broker 能力 |
| 配置 | `xml/dealerStock.xml`、`RLDealerStockPolicy`、`RLDealerQualityResolver`；clock=0.25月，Listing TTL 为0.5/1/2月类，source cap=3倍 | 源码取值已有待核验；新增 cap/来源观察期/价差仍是候选数值，未做经济扫描 |

### 配置冻结（SHA-256）

以下是 baseSHA 对应的仓库内配置，不包含用户 `modSettings` 覆盖或地图配置；本包未修改这些文件。实际安装环境仍须另外取证。

| 文件 | SHA-256 |
|---|---|
| `xml/animals.xml` | `adac9ffa30c5b1dc8b21f354d49c485253d12bcf0180cbcba7f03d0eee95bbed` |
| `xml/breedTraits.xml` | `c89d62bfe10b1bc410085b3cd24d346f56c5dc20833d69e182af12adc7ef2b7f` |
| `xml/dealerStock.xml` | `36a94923a7284737755b7ee95f44b239abea116dcb2267c6bdda321463b0d731` |
| `xml/carcassYield.xml` | `d5d44d8390448db5983c88515e1ef8cbdccd456c86f63166f874b4a20aba2d0a` |
| `xml/breedingValue.xml` | `94cc0d210869d0d831abf2b9d7830aac49c8a2a7f0bce347d448bdbe61177df6` |

## T1–T6 与附录二完成证据映射

| 任务/契约 | 已有源码及离线测试入口 | 判定、剩余工作 |
|---|---|---|
| T1 / B5.1–B5.3 完整键账本 | `RLAnimalIdentity.lua`：完整 `(farmId,uniqueId,country)`、reserveBatch、burn、bindMaterialization、consume、迁移证明、export/import；`test_animalidentity.lua` | 代码已有待核验。非单射编号、跨物种同域、请求幂等有测试；MAX_RAW=99999 与实际网络/XML/显示边界实机待验；不能仅据 live scan 宣称历史唯一 |
| T2 / B5 身份入口 | `RLAnimalIdentityRuntime/World/Checkpoint/Persistence`；出生、Animal.new/setUniqueId、旧商人、AI、rideable 接线；`test_animalidentity_runtime/_entries/_checkpoint.lua`、`test_identity_collision.lua` | 代码已有待核验；实际出生、保存、native counter 对齐实机待验；恢复时回退旧计数器为现有行为，不等于满足所有新渠道的身份保证 |
| T2 / E1、B5.3 旧重复键 | `scripts/core/RealisticLivestock_FSBaseMission.lua:290` 调 `RLAnimalIdentityRepair.run`；Repair 对重复 live key 自动给其中动物换 uniqueId 并尝试修亲缘引用 | **需修改/明确处置边界**：与整合稿“不自动改 ID 或删除动物”的要求冲突。该行为已在基线，不能把它写成安全迁移已通过，也不能未经评估直接修改旧行为 |
| T2 / B5.4 未保存烧号 | `RLAnimalIdentityCheckpoint.flushJournal` 按小时 dirty flush；同代 journal 经校验后 `burnUnsaved`；`test_animalidentity_checkpoint.lua` | **需修改**：分配到下次 flush 之间可丢已显示键，现有设计文档也承认此窗；身份与购买 WAL 的 durable sequence/交叉凭据尚未统一。旧 journal 的忽略策略也需按整合恢复表审查 |
| T3 / B6 生成与实际库存 | `RLDealerPlanner/Generation/SourceFactory/OwnedAdmission/SourceOwnership/OwnedBirth/OwnedProgress`、Scheduler；`test_dealergeneration/dealersourcefactory/dealerownedadmission/dealerownedbirth/dealerownedprogress.lua` | 代码已有待核验。真实来源、固定胎儿、选择及reservation绑定可复用；生成 job 仅内存、一次同步 tick 内执行，未实现持久化 GenerationJob；长回放单候选耗时/分帧预算实机待验 |
| T3 / G、B6 周转 | `RLDealerClock.CHECKPOINT_MONTHS=0.25`；`RLDealerListingRegistry.LIFETIMES`；Scheduler 只补最终缺额、`SOURCE_CAP_FACTOR=3`；`test_dealerclock/dealerlisting/dealergeneration.lua` | 代码已有待核验；**撤回后2月 EXPORTED 离场待实现**，Scheduler 文件明确声明仅3倍cap兜底；不能将已有 dead mother retirement 当活来源离场完成 |
| T4 / B7 报价与整批购买 | `RLDealerAssembly/Service/Purchase/PurchaseAdapter/Quote/QuoteProtocol/Capacity/World/Destination`；`test_dealerpurchase/adapter/quote/capacity/world/destination/runtime.lua` | 代码已有待核验：15秒凭证、5秒预留、严格游标/版本、整批转移后一次扣款、NOT_APPLIED补偿、UNKNOWN暂停及鉴权幂等；真实回调重入、资金统计、容量和孕母实机待验 |
| T4 / E2、I1、U66 购入来源凭证 | 现有 purchase.receipt、transferIds 与 money witnesses 是事务证据 | **待实现**统一 AcquisitionReceipt：未找到完整 originStatus、当时货币basis、body/mandatoryFees/totalPaid、acquiredSnapshotDigest、价格配置版本、savedCheckpointRef/provenanceChain。不能把现有 purchase receipt 当成防倒卖来源账本；旧购买/批量/管理员入口同样需接线 |
| T4 / E3、C07 共同锁 | `RLDealerPurchase` 的 `store.locks[saleId]`；`RLDealerMoneyAdapter` 的 `locks[farmId]`；Scheduler、OwnedProgress 等局部busy/gate | **待实现/需修改**：没有跨普通卖、Broker、HB屠宰、移动/阉割的完整动物键统一资源排序锁。现有局部锁不可证明跨渠道安全，真实旧入口须接线或证明同步不可重入 |
| T4 / B8 保存参与者 | `RLDealerPersistence.lua:5,9` schema1 + placeables/vehicles/farms；Checkpoint 写 stock、career commit 并回读；identity另有 placeables/vehicles/farms/animalSystem | **需修改**：Dealer与identity独立lineage/generation，缺双方可核验同一完整保存代次绑定、身份账本/原生计数器参与证据；不得单凭各自 READY 等同共同保存完整 |
| T4 / B8.4 历史资金结清 | `RLDealerStockService.fromVerifiedDocument` 载入 purchase 终态、不载 live money；`RLDealerPurchaseAdapter.lua:76` 新建 epoch money store；`test_dealerpurchaseadapter.lua:248` SV-01、R10覆盖旧回执查询后再次买入 | **代码已有待核验并需扩展**，不是完全缺失。正常保存路径已区分历史终态与本会话money；但无显式 `settledCheckpoint/HISTORICAL_SETTLED`，缺购买/库存/已确认资金序列与完整保存参与者共同绑定。SV-01用合成participant内容且保留同一world，不能当多笔后转场/死亡/其他收入的实机证明 |
| T4 / B8.3 WAL | `RLDealerJournal` 同步写+回读；Runtime.compareJournal 比较保存/WAL，同代未保存不重放、旧代不一致暂停；`test_dealerjournal/resume/persistence/checkpoint.lua` | 代码已有待核验；**需修改** `RLDealerRuntime.archiveWal`：copyFile后直接deleteFile，未核验拷贝/删除结果或精确回读。归档失败不能算完成；身份烧号顺序也须联审。不得补扣、退款或重放动物 |
| T5 / B9 浏览协议与UI | `RLDealerCatalog/Protocol/Event/Selection/Messages/ClientRequest`，控制台列表/详情/报价/确认/查询；`test_dealergeneration/dealerclientrequest/dealerpurchaseprotocol.lua` | 协议代码已有待核验；**GUI待实现**；旧轮换和v2目前并存，启用同物种后“单库存机制”切换待实现；玩家展示不能直接暴露WAL/schema术语 |
| T6 / B12 实证 | `RLIdentityConsole`、`RLDealerConsole`、`tests/dealer_v2_analyzer.py`、`test_dealer_v2_analyzer.py`；`docs/DEALER_V2_T6_TEST_CARDS.md`、`...TEST_PLAN.md` | 工具代码已有待核验；G01–G12仍标PENDING。圈舍/拖车双头、孕母保存后出生、余额不足、再次购买、未保存退出、受控保存中断、联机均实机待验 |

## A–L 跨方案能力与施工门槛

| 章节 | 本基线结论 |
|---|---|
| A–C 范围/冲突 | 保留既有生理、普通售出、HB、AI职责；C02新ASK、C03 MoneyPolicy、C05来源、C06共同证据、C07共同锁均不能标完成。T/U复用应以上表实际能力为准 |
| D 能力隔离 | 当前只有Dealer整体gate与identity authoritative；价格、预检、结算、物种/地图/transport mode新门控待实现。关闭新价不得删除库存/历史/未决证据 |
| E 身份/来源/互斥 | 身份纯账本与入口已有；历史迁移证明/自动修复冲突/日志窗待处理；AcquisitionReceipt与跨渠道锁待实现 |
| F 价格/复验 | legacy旧买价已有；独立ASK/BID、统一MoneyPolicy/MoneyBreakdown、source cap待实现。现有v2严格revision检查应保留，不套用Broker同额微变政策 |
| G 实际库存/虚拟需求 | Dealer clock/actual owned stock已有；2月活来源离场待实现。Broker独立seed、月初需求、随机流隔离、canonical候选生成待实现 |
| H 分类/参数 | Dealer目录不能直接当Broker条件包；羊/猪/奶羊/HB MILKCOW等能力逐scope核验。月cap、单量、12–36月体验与真实可达性仍待实现/候选数值 |
| I 事务/恢复 | Dealer coordinator可复用；Broker单只删除、一次净额付款、三层quota事务、旧月未决、其自身checkpoint待实现。不得用Trade/HB合同冒充Broker事务 |
| J 分包 | 本文为P0只读映射；P1纯协议/legacy-shadow不依赖先开放Dealer；P2补来源/锁/共同保存；P4保留现有购买设施，仅按scope增量接线；P5–P8不据文件存在提前开放 |
| K 联合验收 | 同ASK/BID入口、完整即时套利路线、切难度/转栏不洗来源、同动物竞争、最后名额竞争、月界及共同保存故障注入均无本次执行证据 |
| L 状态/参数 | D1–D7为此前采纳、实现待核验；不重新悬置，也不把MIGRATION_POINT视为已授权。所有新经济参数需配置版本、独立反例和扫描证据 |

## 后续验证记录要求

开发记录每包的 scope/baseSHA/implementationSHA/configRevision/runtimeMode/map&gameVersion/verification/status/blocker。先重跑 `python tests/run.py` 与 `python tests/test_dealer_v2_analyzer.py` 建立本次离线基线，再按改动添加有独立依据的组合回归。对历史结清尤其增加多笔购买→其他收入→转场/死亡→保存/重载→旧结果查询→新购买，直接比较真实participant内容，而非只比较合成摘要。

实机按已有 G01–G12 卡取证并补整合 K 联合场景；取证前保持新价格 legacy、Broker真实成交关闭、Dealer v2默认关闭。历史文档中的“not integrated”等早期描述已被后续实现部分超越，最终判断以冻结SHA源码与本次实际验证为准。

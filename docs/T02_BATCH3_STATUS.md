# R0-T02 第三批（PR33）实施状态：人工/AI活卖结算收据与运行期恢复

对应方案：`T02_BATCH3_PLAN.md`（外部维护，未纳入本分支）；测试案例 ID 见 `T02_TEST_WORKFLOW.md` 第5节（S组）。
本文记录本批**已实现、离线已验证、未游戏验收**的内容。离线通过不等于游戏发布通过，也不等于完整 T02 完成。

## 1. 基线与堆叠

- 分支 `feat/live-sale-receipts`，从 PR32 固定 head `f27d029`（`feat/contract-adapter`）建立；PR33 的 base 指向 PR32 分支，diff 只含第三批。
- 栈：PR31（T01）→ PR32（合同适配器）→ **PR33（本批）** → PR34（持久化，未开始）。全部保持 OPEN。
- 建分支时 PR32 工作树另有**未提交**的修改（来源 owner 复核、`apply` 内再 recheck、提交前再验证目标）。它们不属于 PR32 的任何 head，本批没有包含。PR32 提交这些修正后，PR33 需 rebase 到新 head，并重跑 S 组和 A/B/C 组。
- 接口版本：`RLLiveSale.SCHEMA = 1`，`POLICY_VERSION = "t02b3-1"`；账本 `RLTradeTransaction.VERSION = 2`（导入仍接受 1）。

## 2. 范围与开关

| 项 | 本批 | 说明 |
|---|---|---|
| 人工出售（`AnimalSellEvent`） | 支持：圈舍、拖车 | 服务端报价不变；TEST 走事务 |
| 牧场主出售（`AIAnimalSellEvent.executeServer`） | 支持：圈舍 | 报价不变；TEST 走事务 |
| 牧场主工资 | 支持 | 每轮每农场一个资金动作，规则不变 |
| 部分成交 | 支持 | 只付确认离开的那几头，批次仍报"未完整完成" |
| 资金收据 | APPLIED / NOT_APPLIED / UNKNOWN | 见第4节 |
| 跨重载/崩溃 | **不支持** | 只在本次运行的内存里；第四批处理 |
| 网络协议 | 不变 | 待核对用现有失败码，详情在日志和 `rlTradeTxReport` |

开关：`rlTradeSaleMode [OFF|SHADOW|TEST]`，仅服务端、仅本次运行，每次加载地图回到 OFF，与合同的 `rlTradeTxMode` 分开。

- **OFF**（默认）：原路径，一行未改。
- **SHADOW**：原路径照常；本模块只做 prepare 并写日志（会不会被锁、会付多少），不加锁、不记账。
- **TEST**：仅测试存档。走 `RLTradeTransaction.executeLiveSale`，不支持的情况直接拒绝，不回退到原路径。

账本与 PR32 共用（`RLContractTrade.store`），因此合同事务待核对时持有的动物、圈舍、农场现金锁同样挡住活卖。

## 3. 保留的业务语义

| 规则 | 实现 |
|---|---|
| 人工：服务端重报价，不用客户端 price/transportPrice | 仍是 `AnimalSellEvent.quoteSale`，未改 |
| 人工净额 = price − fee；AI = price + fee | 按头冻结，累加方式与旧代码逐字相同（人工 `credit + price - fee`，AI `credit + credits[i]`），金额逐位一致（有测试） |
| 部分移除按确认子集结算，并报未完整成功 | 子集按对象判断；人工回失败码、不发消息；AI 报 PARTIAL |
| flush 抛错但全部已离开 | 全额付一次；照旧反馈失败（人工失败码，AI 在 flush 阶段报 PARTIAL） |
| 零额/负额 | 原样调用 addMoney，不取绝对值、不截断 |
| 价格、费用的有限性，归属，疾病，可售 | 仍由原报价函数检查 |
| AI 网络事件不执行经济动作 | 未改；TEST 下也不动账本 |
| 工资规则（owner-changed 不收，sale-refused/sale-failed 收，按农场汇总） | 未改 |

TEST 比 OFF **更严格**的地方（保守拒绝，不是政策变化）：

- 来源队列非空；
- 圈舍里有 flush 会自行删除的成员（骑乘中、零头、占位 ID）；
- 动物带经销商挂牌；
- 报价对象与按完整身份解析到的对象不一致（旧 id 索引误指）；
- 无法建立资金收据（农场、统计项、计数器不可读）；
- 资源被其他事务锁住。

## 4. 资金收据（`RLSaleSettlement`）

一次资金动作 = 对 `g_currentMission:addMoney(amount, farmId, moneyType, true, true)` 的一次调用，每个 paymentId 只调用一次。调用前先写入收据（阶段 RECORDED → CALLING → DONE），所以重入或重复请求同一个 paymentId 时什么都不会再调用。

`addMoney` 没有返回值。按 FS25 v1.23.1 源码，它的副作用依次为：

| 步骤 | 字段 | 期望变化 |
|---|---|---|
| 1 | `farm.money` | + amount |
| 2 | `farm.stats.finances[stat]` 与 `financesVersionCounter` | + amount；计数器 + 1（999999 后归 0） |
| 3 | `farm.stats.moneyEarnedHeroAccum` | + amount（仅 amount > 0） |
| — | 发布 MONEY_CHANGED | 其他 mod 的监听器在此运行，无法观测 |
| 4 | `mission.moneyChanges[type][farm]` | 先累加，再由 broadcastNotifications 发送给农场并**清空**：完整调用后为 nil |

判定（调用前后各读一次）：

- **APPLIED**：步骤 1–3 各恰好一次，且步骤 4 完成（调用返回、总额已清空），或已到达（调用抛错、总额 = 之前 + amount，即 HUD 或广播失败；错误记为 callError，钱已到账）。
- **NOT_APPLIED**：从未调用（调用前检查拒绝：非服务端、旁观农场、农场不存在、统计项缺失、金额非有限），或者调用抛错且任何步骤都没变。
- **UNKNOWN**：其余所有情况——只做了部分步骤（监听器抛错）、某个差额对不上（监听器里又动了钱）、调用返回但一步都没做、调用后字段读不出。

不做的事：不还原钱包快照、不全局替换 addMoney、不返回固定状态、不靠余额差反推。

已知边界：别的 mod 包装 addMoney 后，在这些字段以外做的事看不到（例如给另一个农场付款再抛错）。这种情况下"抛错且无步骤"仍会判为 NOT_APPLIED。

## 5. 来源与恢复决策（`RLSaleRecovery`，纯函数）

| 来源（按对象读取） | 资金收据 | 结果 |
|---|---|---|
| 不可读、集群系统换了、批外成员变化、本批成员重复出现 | 不付款 | SOURCE_UNKNOWN → NEEDS_RECONCILIATION：只撤本批队列项，不再删除、不复活，锁保留 |
| 本批无一离开 | 不付款 | 撤队列并验证 → ROLLED_BACK（验证不过则待核对） |
| 全部离开 | APPLIED | COMMITTED |
| 部分离开 | APPLIED | 先撤幸存者的队列项再付款 → COMMITTED_PARTIAL；幸存者队列撤不掉 → 钱照付，NEEDS_RECONCILIATION |
| 离开的子集 | NOT_APPLIED | 把这些原对象放回（清掉 id，分配新视觉 ID）并核对字段 → ROLLED_BACK；放回失败或字段变了 → 待核对 |
| 离开的子集 | UNKNOWN / 无收据 / 收据不属于本次 | NEEDS_RECONCILIATION：不补款、不复活、不重卖，锁保留 |
| 成交后消息/回复失败 | APPLIED | 经济结果不变，记 notificationError，不再付款 |

锁：`source:<圈舍>`、`cash:farm<N>`、每头 `animal:<身份>`。正常完成即释放；待核对时一直持有到本次运行结束。

- 农场现金锁较保守：一笔待核对的出售会挡住该农场后续的 TEST 出售、合同交付和牧场主买入。
- 工资不受此锁影响，照常收取。

## 6. 接入点与结果映射

- **人工**（`AnimalSellEvent:run`）：权限和报价之后分流。TEST 回复码：
  - 只有 COMMITTED 且移除过程没有报错时回 `SELL_SUCCESS`，并发消息（消息失败只记录）。
  - 其余情况：身份类问题 → `INVALID_CLUSTER`；锁或动物状态 → `CANNOT_BE_SOLD`；其他 → `OBJECT_DOES_NOT_EXIST`。
  - 回复发送失败不影响已确认的成交。
- **AI**（`executeServer(object, identities, seller, ctx, saleId)`）：
  - 字段 requestedCount、removedCount、settledCount、amountGained、quotedAmount、failureStage、reason 的含义不变。
  - 新增 txId、txState、paymentStatus、replayed、originalRemovedCount、restoredCount。
  - removedCount 现在表示"此刻已离开来源的数量"：放回后为 0，原始离开数在 originalRemovedCount，放回数在 restoredCount；来源未知时为 nil。
  - 资金 UNKNOWN 时 settledCount 和 amountGained 为 nil，不伪装成 0。
  - 新拒绝阶段：`locked`、`receipt`、`replay`、`preflight`。
- **执行器**（TEST）：
  - 每次 `executeActions` 是一个执行轮次：`ctx.roundId`，或新分配的 `hr<n>`。不按农场+日期合并，同一天的两个合法轮次互不影响。
  - 出售 ID = `<轮次>-a<动作序号>`。重放同一轮时，出售返回首次结果：行为 `replayed`、不发消息、不贡献工资。
  - 工资动作 ID = `wage:<轮次>:f<农场>`，收据放在 `summary.wageReceipts`；重放不会再扣。工资抛错只记录，不中断其他农场，也不重放出售。
  - 买入在农场现金被锁时跳过，skipReason 为 `cash-held`（同其他运行期拒绝一样收工资），否则仍按真实钱包和空位验证。
- **控制台**：
  - `rlTradeSaleMode`：仅服务端。
  - `rlTradeTxReport [id]`：增加出售记录（离开、留下、放回的子集，带符号金额，收据与证据）和工资动作；只读，不提供补款、解锁、恢复或重试。

## 7. 离线证据

`tests/test_live_sale.lua`，147 项。
真实代码：

- FS25 资金路径摘录（`tests/fixtures/fs25_money.lua`：addMoney、addMoneyChange、broadcastNotifications、Farm:changeBalance、FarmStats，注明行号和 SHA256；仅把反编译出的 goto 写成等价条件）；
- 基础版集群队列/flush 摘录；
- RLRM 集群系统原文（经 `giants_lua.lua` 改写 `continue`）；
- `AnimalSellEvent`、`AIAnimalSellEvent`、执行器、消息模块与 T02 模块。

替身（不能作为引擎证明）：农场表、HUD/网络发送、圈舍视觉动物、事件与消息、连接。

| ID | 结果 |
|---|---|
| S01 | 人工两头：付 (1000−40)+(800−30) 一次，统计项和发送的金额一致，消息按实付金额；与旧代码累加逐位一致（含 0.1/0.2/1e16 混合）；AI 两头：付 price+fee |
| S02 | flush 中途抛错：只付离开的那头，幸存者留在圈舍且已撤出队列，后续 flush 不会误删；人工回失败码、无消息；AI 报 PARTIAL@flush；全部离开后视觉更新抛错：全额付一次，反馈同旧代码 |
| S03 | flush 后列表不可读：SOURCE_UNKNOWN，不付款、锁保留、不重删、不复活；同圈舍、同农场的下一笔被锁挡住；批外成员变化：AI FAILED@verify，removedCount 为 nil；旧索引误指：只付真正离开的对象 |
| S04 | 付款前农场消失 → NOT_CALLED → 原对象放回（基因、体重不变，新视觉 ID）→ ROLLED_BACK；包装器在任何步骤前抛错 → NOT_APPLIED → 放回，AI 报 removedCount 0（原始 1、放回 1）；入队抛错 → 无移除、无付款、队列已清 |
| S05 | MONEY_CHANGED 监听器抛错：UNKNOWN，钱已动一次，不退款、不复活，同一 paymentId 不会再调用；HUD/广播抛错：APPLIED；监听器里又动了钱：UNKNOWN；调用返回但一步没做：UNKNOWN，不当成未付 |
| S06 | 调用后字段不可读：UNKNOWN；该 paymentId 下已有别的收据：不付款、不当 APPLIED，待核对；准备阶段无法建立收据：在移除前就拒绝 |
| S07 | 部分离开 + NOT_APPLIED：只放回离开的那头，不重复添加；重新添加时 flush 抛错：不报 ROLLED_BACK，动物恰好一份，锁保留；放回后字段已变：待核对 |
| S08 | 部分成交的 AI 重放：返回首次结果，标记 replayed，不卖、不付；同 ID 不同请求：collision；换 ID 卖已离开的动物：identity；人工重复请求：拒绝，只付一次 |
| S09 | 付款期间重入、卖同一圈舍：被锁拒绝；付款前（flush 期间）钱包有合法变化：收据仍为 APPLIED，两笔都保留 |
| S10 | 净额 0：靠统计计数器证明 APPLIED；净额 −30：原样扣款，money earned 不变；NaN、无穷、负价：被原报价拒绝；总额溢出：拒绝@price |
| S11 | 消息抛错：仍回 SUCCESS、只付一次、记录错误；回复发送抛错：成交保留、只付一次 |
| S12 | AI 网络事件（来自客户端或服务端）在 TEST 下：不卖、不记账；客户端上的控制台：拒绝 |
| S13 | owner-changed：不收工资、不记账；sale-refused、sale-failed（已放回）：收工资；mark 模式：不变 |
| S14 | 同农场多个动作：一个工资动作收合计；同一轮重放：不卖、不付、不扣、无消息；同一天第二个合法轮次：有自己的工资动作 |
| S15 | 工资在任何步骤前抛错：记 NOT_APPLIED，出售不受影响，重放不再尝试；工资监听器抛错：UNKNOWN，不重扣 |
| S16 | 出售付款未知 → 买入因 `cash-held` 跳过；出售已付 → 买入按真实钱包通过；出售被拒 → 买入按真实钱包判 no-money |
| S17 | 导出/导入：COMMITTED_PARTIAL 保留且不再上锁，待核对仍上锁，收据保留；部分成交记录导入后只能 REPLAY；付款中断（无最终状态）导入为 UNKNOWN；坏金额、未知状态拒绝；schema 1 仍可导入；没有写存档的代码 |
| S18 | 拖车：不收运费，无圈舍消息；出售过程中改价：按冻结报价付；有 flush 会自删的成员：拒绝；无权限、他场圈舍：原闸门拒绝；被合同事务锁住的动物：不能卖 |
| 协调器 | 每个适配器步骤抛错、未验证的恢复、未知收据状态、无一离开、成交后通知失败、同 ID 重入（IN_PROGRESS）、缺方法、合同记录当出售运行：结果均符合第5节 |
| 收据 | 对真实资金代码：所有步骤各一次；旁观农场、不存在的农场、坏金额、无统计项、非服务端：调用前拒绝；游戏自身的农场查询抛错：NOT_APPLIED；HUD 抛错：APPLIED；挂起的 HUD 总额随本次一起发送并清空；同 paymentId 自身重入：不重复付款；收据中没有对象引用 |
| OFF/SHADOW | OFF：旧路径卖出并付款，无记录、无收据、无轮次；SHADOW：旧路径卖出，无记录、无锁、无收据，写日志 |

全套离线测试：

- lupa 2.8 默认运行时（Lua 5.5）：1073/1073，exit 0。
- Lua 5.4：1073/1073。
- Lua 5.1：1064/1064，其中 `test_dealerstock.lua` 因其自身 `read("a")` 无法在 5.1 下加载（既有问题，与本批无关）。
- 本批与受影响的五套（live_sale 147、contract_trade 69、trade_transaction 42、sale 52、ai_sale 110）在 Lua 5.1 下全部通过。
- 第二批 A/B/C 组（test_contract_trade）在新账本 schema 下不变：69/69。

Lua 5.1 运行方式：测试框架用 `loadstring` 垫片代替 `load(字符串)`，不改仓库代码。

## 8. 仍未完成 / 未验收

- **未游戏验收**：单机、主机、专服都未执行。建议做法：
  1. 在测试存档中执行 `rlTradeSaleMode SHADOW`，看日志；再切到 `TEST`。
  2. 先人工单头、多头，再拖车，然后让牧场主按天执行。
  3. 用 `rlTradeTxReport` 对照钱包、财务统计（soldAnimals / herdsmanWages）、HUD 金额提示和圈舍。
  4. 需要在引擎中确认：
     - `farm.stats.finances`、`financesVersionCounter`、`moneyEarnedHeroAccum`、`mission.moneyChanges` 在真实游戏里可读，且与 v1.23.1 源码一致；
     - forceShow 的通知确实会清空总额；
     - 视觉动物、客户端同步；
     - 专服上 `getFarmId()` 与 HUD 的分支。
- **持久化**：账本、收据、锁只在内存中，读档后全部消失。待核对状态、轮次号、出售 ID、工资 ID 都不跨重启；重启后同一轮次号可能被复用（内存中已无旧记录）。跨重启的幂等和恢复留给 PR34。
- **锁的覆盖面**：内存锁只挡 T02 路径，挡不住 OFF 路径、经销商、疾病淘汰、HB 加工或其他 mod。
- **收据能力边界**：
  - 其他 mod 在可观测字段之外的副作用无法证明；
  - UNKNOWN 没有自动解决办法，只能人工核对；
  - 没有补款、解锁或强制恢复的工具。
- **网络**：回复码未扩展，待核对与普通失败对客户端无法区分。
- **经济结果不变**：本批不改价格、运费、工资、肉量或费率；OFF 时行为与之前逐字相同。

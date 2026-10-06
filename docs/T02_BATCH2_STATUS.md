# R0-T02 第二批（PR32）实施状态：公共合同受控提交与恢复

对应方案：`T02_BATCH2_PLAN.md`（外部维护，未纳入本分支）；测试案例 ID 见 `T02_TEST_WORKFLOW.md`。
本文记录本批**已实现、离线已验证、未游戏验收**的内容。代码通过不等于游戏发布通过，也不等于完整 T02 完成。

## 1. 基线与堆叠

- 分支 `feat/contract-adapter`，PR32 的 base 是 PR31 分支 `feat/meat-math-trade-report`（T01 及其评审修正 `6bbb74d`）。
- 第一批 `6314af9` 已 rebase 到 `6bbb74d` 上，作为本分支第一个提交（内容不变，仅解决 CHANGELOG 冲突）。
  随后 `6a02c97` 调整影子计划读取更严格的 T01 报价：无订单／无农场 → `NO_ORDER`，单头 `CANNOT_AFFORD` 交给整批现金检查；第一批原有测试全部保留并通过。
- PR31 合并后，本 PR 改 base 为 dev，并对最新 dev 重新核对差异和测试。

## 2. 选用路径 A（调用真实 HB 函数 + 逐字段收据）

原因：改动最小，HB 的订单选择、扣费顺序、state/raiseActive/视觉刷新都由 HB 自身执行；本批不复制 HB 的 state 常量和调度逻辑。

`RLHBContractAdapter`（目标）：

- **整批一次调用** `contractProductionDeliver(farmId, fillType, 合计输入量)`。HB 的费用和输入量对数量是线性的，与旧路径逐头调用在经济上一致；只少了逐头的 0.001 门槛重复判定。
- **调用前**冻结：订单对象及其 id、recipeId、配方指纹（输入、输出、费用、费用输入、主产出）、本农场其他订单，以及钱包。按 HB 自身公式确认可整批接纳：(钱 + 信用)/feePerBatch × 输入量 ≥ 数量，不加容差。
- **调用后**逐字段记录：feeCredit、钱包、order.fee、buffered、totalDelivered、totalDeliveredAmount、state，以及其他订单。
- `verify` 要求 accepted 等于请求数量，且每个字段等于 HB 表达式对该数量算出的值（精确相等，因为运算式相同）。任何部分、零、非数字返回、抛错、转到别的订单、配方变化都不通过。
- `rollback` 只撤销本事务的变化，且只在字段仍等于本事务写入的值时执行，否则判定为 `CHANGED_SINCE`，不覆盖他人改动：
  - 用 `explain()` 判定观测结果：候选接纳量为全额或返回的数值。HB 的步骤依次为 信用 → 钱 → order.fee → 三个输入量 → state，观测结果必须是这些步骤按顺序执行的一个前缀。
  - 无法解释时记为 `DELTA_UNEXPLAINED`，进入待核对，不退款。
  - 退款通过 `addMoney(+cash, PRODUCTION_COSTS)`，冲回生产成本统计。
  - 回退后再刷新一次 HB 视觉。
  - 回退是幂等的，重复调用不会再退一次款。
- **版本门槛**：`g_modManager:getModByName(placeable.customEnvironment).version` 必须为 `1.5.0.0 Beta2`，否则 `UNSUPPORTED_HB_VERSION`。

已知不可撤销或无法证明的部分：

- `raiseActive` 无法撤销（设施会空转更新一次）。
- 退款会计入 farm 的 "moneyEarned" 统计。
- 若有其他 mod 覆写了 deliver，它在上述字段之外做的事无法观测。
- 视觉显示和网络同步未在引擎中验证。

## 3. 来源适配器

`RLTradeSourceAdapter`（圈舍 PEN、拖车 TRAILER）：

- **绑定**：
  - 按完整身份（farmId、uniqueId、出生国）在实时成员列表中按对象唯一匹配，不用 idToIndex。
  - 待加／待删队列必须为空（false 值也算非空）。
  - 来源中不得有会被 flush 自行删除的成员（骑乘中、零头、占位 ID）。
  - 动物不得已死亡、已售或带经销商挂牌（sale）。
  - 冻结每头的业务字段快照，排除 id、idFull、clusterSystem、isDirty。
- **移除**：走公共路径 `addPendingRemoveCluster` + `updateNow`，即 RLRM 真实的 updateClusters（removeCluster、视觉计数、idToIndex、广播、发布、视觉更新）。之后用对象身份核对：本批全部离开，其他成员各保留一份，队列清空。
- **恢复**：
  - 仍在来源中的动物：只清本批的队列项（re-add 会产生重复）。
  - 已离开的动物：以原对象重新加入，先清空 id 和 idFull，由圈舍分配新的视觉 ID，不复用已删除的引擎 ID。
  - 恢复后比对业务字段快照。回退是幂等的。
- 先恢复来源，再撤销目标；来源无法恢复时**不撤销目标**（避免两边都失去资产），保持待核对。
- **发现（未改动）**：在真实的 GIANTS `Utils.overwrittenFunction` 下，RLRM 的静态 `AnimalClusterSystem.new(superFunc, isServer, …)` 收到的参数是错位的，所以实时集群系统的 `isServer` 存的是基础版 new 函数（客户端上也是如此）。适配器因此改用来源对象的 `isServer` 判断服务端。是否修正 RLRM 的这个签名，另行决定。

## 4. 服务端入口与受控接入

`RLContractTrade`：

- **模式**：
  - `OFF`（默认）。每次地图加载都 `reset()` 回 OFF 并清空账本，从不存档。
  - `SHADOW`：只执行 prepare 并写日志，旧路径照常运行，不加锁、不写记录。
  - `TEST`：仅用于测试存档。公共合同目标走事务，不支持时明确拒绝，不回退到旧的逐头路径。
  - 农场屠夫等非合同目标在任何模式下都走原路径，本批未接管。
- **prepare 依次检查**：
  1. 服务端。
  2. tradeAnimals 权限：连接方所属农场必须等于来源所有者（`RLPermissionHelper.authorizeConnection`）。
  3. 来源所有者等于交付农场（访问权不等于所有权）。
  4. 目标访问权。
  5. HB 版本。
  6. 身份列表必须是稠密数组、无重复、身份完整。
  7. 来源绑定。
  8. 逐头检查：仅限 COW、未患病、报价 SUPPORTED、单位为 WEIGHTED_BATCH、配方 ALIGNED、所有头同一输入。
  9. 整批预算和容量（`RLContractPlan`，信用一次、现金共享）。
  10. HB 绑定。
  11. 请求指纹：`v1|policy|farm|source|target|order|recipe fp|amount|有序身份列表`。
  12. 资源锁：cash:farm、order、input、source 以及每头 animal。
- **执行**：`RLTradeTransaction.executeContract` 依次为 preflight（双方重新核对：订单对象、配方指纹、HB 订单选择、整批可付、来源成员和队列、模式）→ 目标 → 来源 → 提交。失败时先撤来源再撤目标；无法证明恢复时进入 `NEEDS_RECONCILIATION` 并保留锁。
- **移动事件**：`AnimalMoveEvent:run` 在原有逐头校验之后、旧逐头路径之前分流。TEST 结果映射为 MOVE 错误码回复客户端。
- **控制台**：
  - `rlTradeTxMode [OFF|SHADOW|TEST]`：服务端可用，仅对本次运行有效。
  - `rlTradeTxReport [txId]`：只读，显示阶段、收据和持有的锁。没有补款、解锁或重试命令。
- 交易 ID 由服务端按序生成。重复的网络请求会因动物已离开（`ANIMAL_NOT_FOUND`）或资源被锁（`RESOURCE_BUSY`）而失败，不会二次成交。

## 5. 离线证据（`tests/test_contract_trade.lua`，69 项；Lua 5.4 与 5.1 均通过）

**真实代码**：

- HB deliver 摘录（`hb_contract_delivery.lua`）。
- 基础版 AnimalClusterSystem 的 new、队列与 flush，以及 GIANTS `Utils` 的精确摘录（`fs25_cluster_queue.lua`）。
- RLRM 的 `RealisticLivestock_AnimalClusterSystem.lua` 原文，经 `giants_lua.lua` 改写 `continue` 后运行（仅改写语法，不改逻辑）。
- `Animal:setClusterSystem` / `getNumAnimals`、`RLDiseaseSaleGate`、报价、计划、协调器。

**引擎替身**（不能作为引擎证明）：钱包（按 Farm:changeBalance 的算术）、圈舍视觉动物、事件广播和消息。

| ID | 结果 |
|---|---|
| A01/A02 | 空、稀疏、字符串键、元表、重复身份、缺国家、同 uniqueId 不同国家：整批拒绝，无任何变化 |
| A03 | 他场来源 NOT_OWNER；无 trade 权限 NO_PERMISSION |
| A04 | 患病、低于设施年龄、来源中有骑乘成员、MILKCOW、带挂牌：均拒绝；prepare 后来源有待加项：preflight 拒绝 |
| A05 | 队列中有 false 值项也算忙 |
| A06 | 无订单拒绝（客户端收到 NOT_ENOUGH_SPACE）；多订单时取 HB 自身选择的最低 id |
| A07/A08/B09 | 配方费变化、同 id 订单被重建、新出现更低 id 订单：preflight 拒绝，无变化 |
| A09/B02 | 三头一次调用，信用只用一次 |
| A10 | 钱差 1e-9 拒绝（不部分接纳）；恰好够则提交 |
| A11/A12 | 待核对期间同一动物新请求 RESOURCE_BUSY；提交后重复请求 ANIMAL_NOT_FOUND |
| B01/B13 | 单头完整提交；信用全额、部分、为零三种情况下现金正确；费用只取配方一次（199.9×factor） |
| B03 | 半额接纳 / 返回 0 / 字段全额但返回非数字：ROLLED_BACK，订单、信用、钱、生产成本统计全部复原，动物保留 |
| B05/B06/B07/B08 | addMoney 动钱前抛错、动钱后抛错、raiseActive 抛错、合同视觉抛错：全部 ROLLED_BACK，退款恰好一次 |
| B06 未知 | 其他 mod 在 addMoney 内又动了钱：NEEDS_RECONCILIATION，不退款，保留锁，来源未动 |
| B10 | 退款抛错：NEEDS_RECONCILIATION；记录不会被自动重试 |
| B11 | deliver 内出现 HB 不会做的变化：DELTA_UNEXPLAINED；提交后订单被他人改动、随后来源失败：来源已复原，目标不覆盖 → 待核对 |
| B12 | 交付后钱包不可读：不猜，待核对 |
| C01/C06 | 入队中途抛错：复原；之后正常 flush 不误删存活动物 |
| C02/C03/C04/C10 | flush 已删除后视觉更新抛错：按真实成员列表复原原对象（基因、体重、体况、妊娠不变），获得新视觉 ID，视觉计数复原，idToIndex 一致；批外成员不受影响 |
| C05 | 来源恢复失败：目标**不撤销**，待核对，锁保留 |
| C08 | 拖车来源：提交，以及目标失败时来源未被动过 |
| 模式 | SHADOW 不加锁、不记录、无变化；OFF 时移动事件走旧路径（旧路径仍把半额计作整头，已知且未改）；TEST 移动事件只调用一次 deliver，失败不回退旧路径 |

另外，全套离线测试 926/926（exit 0）。

## 6. 仍未完成 / 未验收

- **未游戏验收**：单机、主机、专服都未执行。建议做法：
  - 在测试存档中执行 `rlTradeTxMode SHADOW`，看日志；再切到 `TEST`。
  - 先送单头，再送多头。
  - 用 `rlTradeTxReport` 对照订单、信用、钱包和圈舍。
  - 需要确认：HB 的 `customEnvironment` 与 version 读取、圈舍和拖车的视觉动物、客户端同步。
- **持久化**：账本只在内存中，读档后待核对状态丢失。TEST 只能用于测试存档；跨重启幂等与恢复留给后续批次（PR34）。
- **内存锁的覆盖面**：RLRM 的内存锁拦不住其他路径，例如人工出售、牧场主、订单取消、HB 加工推进和外部 mod。待核对期间的动物仍可能被这些路径动到。
- **其余后续批次**：活卖收据（PR33），农场屠夫、动物转换及其他设施的接入，旧订单迁移，以及 1000→270 等政策调整。
- **经济结果不变**：本批不改肉量、费率、活价或配方；OFF 时经济结果与之前完全一致。

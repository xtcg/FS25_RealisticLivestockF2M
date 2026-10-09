# R0-T02 第四批（PR34）实施状态：账本持久化、一致存档点与启动恢复

对应方案：`T02_BATCH4_PLAN.md`（外部维护，未纳入本分支）；测试案例 ID 见 `T02_TEST_WORKFLOW.md` 第6节（J组）。
本文记录**已实现、离线已验证、未游戏验收**的内容。离线通过不等于引擎存档行为已证明。

## 1. 基线与堆叠

- 分支 `feat/trade-persistence`，从 PR33 head `3f092a1` 建立（该 head 已合入 PR32 修复 `4f9d754`）。PR34 的 base 指向 PR33 分支。
- 栈：PR31 → PR32 → PR33 → **PR34**，全部保持 OPEN。父层再修正时，PR34 需要合入父层新 head，并重跑 J 组和受影响的 A/B/C/S 组。
- 版本：
  - 账本文件 `rm_RlTradeLedger.xml` schema 1；
  - 其中的事务账本 `RLTradeTransaction.VERSION = 2`（导入仍接受 1）；
  - 活卖 `RLLiveSale.SCHEMA = 1`。

## 2. 保存/加载链审计（FS25 v1.23.1 源码）

### 2.1 保存时序

`SavegameController:saveSavegame` 的流程：

1. （PC）`backupSavegame` 把旧存档目录的全部文件复制到备份目录。
2. 引擎调用 `saveWriteSavegameStart`，通过回调 `onSaveStartComplete(errorCode, savegameDirectory)` 返回目录，随后 `setSavegameDirectory`。
3. **在同一次同步调用里** `FSCareerMissionInfo:saveToXMLFile()` 写出全部 XML。
4. 密度图等写入是异步任务，最后由 `saveWriteSavegameFinish` 收尾，并回调 `onSaveComplete(errorCode, finalDirectory)`。

第 3 步是同步执行的单个 Lua 函数，期间不会运行任何帧更新、网络事件或生产推进，因此这些 XML 描述的是同一时刻。本批把账本挂在这个边界上。

### 2.2 参与者表

| 文件 | 内容 | 写入点（顺序） | 加载读取点 | 成功/失败信号 | 标记写法 |
|---|---|---|---|---|---|
| `placeables.xml` | 圈舍动物（RLRM 集群）、HB 合同订单 | `PlaceableSystem:save` → `saveToXML` → `xmlFile:save()`（第1） | 游戏加载 placeable；本批读根属性 | 返回值被忽略 → 本批回读校验 | 在 `saveToXML` 前置钩子中，通过游戏自己打开的文档写 `placeables#rlTradeCheckpoint` |
| `vehicles.xml` | 牲畜拖车 | `VehicleSystem:save` → `saveToXML`（内部 `save(false, true)`）（第2） | 同上 | 忽略错误 → 回读 | `saveToXML` 前置钩子，写 `vehicles#…` |
| `farms.xml` | 钱、贷款、财务统计 | `FarmManager:saveToXMLFile`（第3，在 economy/players 等之后） | 同上 | 无返回值 → 回读 | `Farm:saveToXMLFile` 后置钩子（只针对非旁观农场），写 `farms#…` |
| `careerSavegame.xml` | 存档总表 | 基础版在函数末尾 `saveXMLFile`（第4） | 本批读根属性 | 返回 bool | **提交标记**：在本批的后置钩子中最后写入，然后再存一次 |
| `rm_RlAnimalSystem.xml`、`rm_RlSettings.xml` | RLRM 自有文件 | RLRM 的后置钩子（第5） | RLRM | — | 不参与 |
| `rm_RlTradeLedger.xml` | 账本 | 本批后置钩子，排在 RLRM 之后（第6） | 本批 | `save()` 返回 bool，再回读校验 schema、摘要和代次 | 头部包含 lineage 和 generation |

其他说明：

- 设置的独立保存（`RLSettings.saveToXMLFile`）不经过上面的边界，**不会**推进 generation。
- `moneyEarnedHeroAccum` 不随存档保存，只是收据的运行期证据。
- 无法从 Lua 核实、需在引擎中确认的项：
  - `saveWriteSavegameStart` 给的是不是临时目录，`Finish` 是否原子替换；
  - 存档 XML 的 schema 是否会对根节点上的未知属性报警；
  - 16 KB 的属性值是否受限；
  - `io` 能否在存档目录写 quarantine 文件；
  - 专服自动保存和主机保存走的是否是同一条路径。

## 3. 能力矩阵

| 等级 | 能力 | 本批 | 证据 |
|---|---|---|---|
| L1 | 正常完整保存后重载：终态去重、未完成隔离 | **支持** | J01/J02/J13/J14/J15/J16/J19 |
| L2 | 保存中断或文件不完整时检出并安全拒绝 | **支持**（检出后关闭全部新 T02 事务；旧路径不受影响） | J03/J07/J08/J17/J18/J20 |
| L3 | 崩溃后自动完成或回退 | **不支持**：任何路径都不自动补款、退款、复活或解锁 | J15：加载前后资产不变 |

唯一会在加载时改动账本的情况：从未离开 PREPARED 的记录（history 只有 PREPARED，说明没有任何适配器回调运行过）会标为 REJECTED（`CANCELLED_AT_RELOAD:NEVER_STARTED`）并释放锁。这只是记账，不碰任何资产。

## 4. 模块

| 模块 | 职责 |
|---|---|
| `RLTradePersistence`（纯） | 数据检查（有限数、类型、环、深度、数量、长度）；规范化文本（排序键、带类型、长度前缀）及严格解析（重复键、坏类型、坏长度、截断、尾随文本都拒绝）；百分号编码成纯 ASCII，按 16 KB 分块；两个 31 位多项式校验和；证据清洗（只用于收据）；保留量压缩 |
| `RLTradeRecovery`（纯） | 加载判定（FRESH / READY / RECOVERY_REQUIRED 及原因）；逐记录判定 |
| `RLTradeCheckpoint` | 存档钩子（generation 门禁、参与者标记、写账本并回读、回读参与者、提交标记、记录引擎结果）；加载核对；启动门禁；epoch 标签；只读的锁重绑报告；隔离文件 |
| `RLTradeTransaction` | `begin` 增加 `store.admit` 门禁；导入时已待核对的记录保留原因，其他未完成记录的原因注明所处阶段 |
| `RLContractTrade` / `RLLiveSale` | ID 带 epoch 标签；只有加载核对通过（READY）后才能设 TEST，设 TEST 即为本存档启用账本 |

## 5. 账本内容（schema 1）

- **头部**：schema、lineage、generation、integrity（OK / RECOVERY_REQUIRED）、reason、digest。
- **数据**：
  - 序号：contract、sale、round；
  - epoch；
  - 参与者集合；
  - 事务账本：records（含 sale 子集和金额）与 payments（全部资金收据：出售、工资）；
  - 收据证据（合同和活卖，已清洗，只保留明细窗口内的）；
  - 保留量统计；
  - 上次加载的判定。
- **不保存**：对象引用、nodeId、客户端数据。动物用完整身份，来源用 placeable/vehicle 的 uniqueId，订单用 HB 的 order id。

## 6. 保存时序与失败处理

1. **前置钩子**：generation 立即加一（即使本次保存中断，这个号也不会再给下一次用），冻结账本数据。保存期间所有新 T02 事务一律拒绝（`SAVE_IN_PROGRESS`）。
2. **游戏写出资产**：每个参与者文件根上写 `lineage:G`。
3. **后置钩子**（在 RLRM 之后）：
   - 写账本 → `save()` → 回读账本（schema、digest、G）→ 回读三个参与者文件（标过的必须是 G，没标过的必须无标记）；
   - 全部通过后，才把提交标记写进 career 内存文档 → `WRITTEN`。career 文档由 `FSCareerMissionInfo` 以空文件名创建，`saveXMLFile` 对它必然失败；引擎在本轮之后用 `saveXMLFileToMemory` 序列化它，由 `saveWriteSavegameFinish` 写成 careerSavegame.xml（PERSIST01-01：旧实现要求 `saveXMLFile` 成功，每次保存都误报 `CAREER_MARK_FAILED`）；
   - 引擎回调 `onSaveComplete` 报错 → `FAILED`；成功则从最终存档目录回读 career 标记、账本（digest、G）和三个参与者标记，全部一致才 `COMMITTED`，否则 `INCOMPLETE`（`CAREER_MARK_NOT_IN_SAVE`、`LEDGER_NOT_IN_SAVE`、`PARTICIPANT_NOT_IN_SAVE`）。`WRITTEN` 到回调之间文件已不再变化，T02 保持开放。
4. **任何一步失败或中断**（`INCOMPLETE`、`ABORTED`、`FAILED`）：本次运行内新 T02 事务关闭（`LAST_SAVE_…`），直到下一次保存完整完成；加载时一定判为混代或缺失。
5. 门禁只能挡住经过 T02 的入口。保存期间其他 mod 或旧路径的同步改动由游戏写入其后的文件中（J05），账本不对它们作任何声明。

## 7. 加载与恢复门禁

- `loadMap`：建立新实例（服务端 LOADING，客户端 DISABLED），关闭 T02，TEST 不可设。
- RLRM 的 `onStartMission` 末尾（游戏已加载全部文件、身份修复之后、第一个牧场主日之前）：
  1. 读账本和四个标记，按下表判定；
  2. 导入记录、收据和序号，开始新 epoch；
  3. 生成锁重绑报告（只报告 FOUND / MISSING / UNCHECKED，从不移动或释放锁）。

| 判定 | 条件 | 结果 |
|---|---|---|
| FRESH | 无账本、无任何标记 | 开放；不启用账本（从未启用过） |
| READY（L1） | 四个标记都等于账本的 `lineage:G` | 终态只能重放；未完成的为 NEEDS_RECONCILIATION，锁限于自身资源（无关工作可以进行）；从未开始的取消 |
| RECOVERY_REQUIRED（L2） | 账本缺失但有标记（LEDGER_MISSING）；账本坏、过新或被改（LEDGER_UNREADABLE：解析、schema、摘要、记录、数量）；混代（MIXED_CHECKPOINT）；携带的待核对状态（CARRIED） | 能读出的记录照常导入供报告使用；全部新 T02 拒绝，TEST 拒绝；损坏的原文保存为 `rm_RlTradeLedger.quarantine.txt`；之后每次保存都写 RECOVERY_REQUIRED，不会被洗白；generation 从磁盘上的最大值继续 |

客户端：不读、不写，不执行任何恢复。

## 8. 保留量与上限

- **detailed 100**：最近 100 条已完成记录保留历史和收据。
- **tombstones 500**：更早的已完成记录只保留 id、kind、指纹、资源、终态、原因、序号和出售子集。
- **超出部分**：只修剪**过去 epoch** 的已完成记录及其收据，以及过去 epoch 中超过 500 条的工资收据。
- **永不修剪**：未完成记录、UNKNOWN 收据、当前 epoch 的任何记录。
- **修剪为什么安全**：ID 由服务端发放并带 epoch 标签；没有任何入口接受外部传入的 ID；玩家重复出售靠"动物已不在"拒绝，与记录无关。
- **当前 epoch 记录上限 5000**：超过后拒绝新事务（`LEDGER_FULL`），不丢弃任何内容。
- **处于 RECOVERY_REQUIRED 时**：不修剪。
- **单值长度上限 256 KB**：一千头一批的指纹会列出全部身份。

## 9. 离线证据

`tests/test_trade_persistence.lua`，148 项。每次保存都把真实文件写到临时存档目录，再读回来。

真实代码：

- 本批模块；
- RLRM 真实的 careerSavegame 后置钩子；
- FS25 资金路径摘录；
- 保存链摘录（`fs25_save_pass.lua`：Utils、XMLFile.setTable、PlaceableSystem:save、VehicleSystem:save/saveToXML、FarmManager:saveToXMLFile，注明行号和 SHA256）。

替身：XML 读写（`xml_disk.lua`，写真实字节并可注入故障）、精简的 career 保存、资产字段、农场、HUD。

| ID | 结果 |
|---|---|
| 编码 | 任意字节字符串、逐位一致的数值、布尔、嵌套、整数键都能往返；存储文本是纯 ASCII；解析拒绝 10 类非法输入；check 拒绝 NaN、inf、函数、非整数键、环、过深、过多、过长 |
| J01 | 正常保存并重载：READY L1；钱、圈舍、订单与账本来自同一存档；终态只能重放；未知收据的出售保持待核对且锁定（含农场现金）；另一农场的无关出售可以运行；第二次保存 G=2 |
| J02 | 在出售的付款步骤中触发保存：该存档加载后为 NEEDS_RECONCILIATION（原因注明 SETTLING），不续做，也不凭空生成收据；未开始的 PREPARED 记录加载后取消，无锁 |
| J03 | 8 种文件故障（placeables 抛错、vehicles 保存失败、farms 截断或抛错、账本失败或截断、引擎写 career 失败或截断）：本次运行如实记为 ABORTED、INCOMPLETE 或 FAILED，T02 关闭；加载时为 RECOVERY_REQUIRED（L2）。唯一例外：任何文件被覆盖之前就抛错 → 上一个完整存档原样加载为 READY（之后的那笔出售丢失，等同于回到存档）。引擎报错 → FAILED；随后一次完整保存即重新开放 |
| J04 | 写出顺序：资产 → RLRM → 账本 → 提交标记；保存期间 begin 被拒（SAVE_IN_PROGRESS），保存后重新开放 |
| J05 | 保存期间非 T02 的合法改钱写入其后的 farms.xml |
| J06 | 设置保存不写账本，也不推进 generation |
| J07 | 旧账本配新资产、新账本配旧 placeables、只有旧 career 标记：都判为 MIXED 并点名文件；下一次保存从磁盘上的最大 generation 继续 |
| J08 | 账本被删（LEDGER_MISSING，不当成新安装）；非 XML（保留原文，下次保存写出 quarantine，之后加载仍为 CARRIED）；schema 过新；分块被改（DIGEST_MISMATCH）；截断；lineage 坏；NaN、重复键、未知状态（重算摘要后仍拒绝）；超出数量上限 |
| J09 | 旧存档首次安装：FRESH，不写任何东西；设 TEST 后启用；schema 1 的事务账本可导入，其中运行中的记录被锁定 |
| J10 | 启动时的身份修复数量写入报告；锁不移动 |
| J11 | onStartMission 之前 T02 被拒（RECOVERY_GATE:LOADING），TEST 不可设；客户端为 DISABLED |
| J12 | 待核对出售的圈舍已不存在：锁保留，报告 MISSING；同身份的新动物仍被锁住 |
| J13 | 订单之后被加工、钱另有变动：仍为 READY，合同记录仍是 COMMITTED |
| J14 | 同 ID 同请求：REPLAY；改了请求：ID_COLLISION；工资：REPLAY 不重扣；新 ID 带新 epoch |
| J15 | 加载不改钱、不改圈舍；重复加载原因和历史不增长 |
| J16 | UNKNOWN 收据跨重载保持 UNKNOWN，不会再次尝试 |
| J17 | 客户端：不读不写（主机或专服崩溃只能用"文件不完整"的方式离线模拟） |
| J18 | 完整备份 G1：READY G1，新 ID 不与丢失的 G2 重复，之后续写 G2；复制的存档可加载；只恢复单个 XML 判为混代 |
| J19 | 同一进程切换到另一存档：空账本，不带入锁或记录；切回原存档恢复其记录 |
| J20 | 模式切回 OFF 仍写账本；卸载 mod 后保存再重装 → 标记缺失 → 关闭 |
| J21 | 最后一次保存之后的出售在重载后不存在，不会被重放 |
| J22 | 本 epoch 内不修剪；进入下一 epoch 后为 100 + 500，最旧的被修剪；待核对记录和 UNKNOWN 收据保留；工资收据保留 500；保留的 ID 仍可 REPLAY；达到上限 → LEDGER_FULL |
| J23 | 2000 条记录（含一笔 1000 头）：保存约 0.7 s、加载约 0.4 s（替身 XML，不代表引擎耗时），账本约 1.6 MB |
| J24 | 报告显示账本状态、generation、加载判定、身份修复次数，以及每把锁指向的资源；报告只读；没有解锁或补款命令；RECOVERY_REQUIRED 时报告写明原因，TEST 被拒（附原因），SHADOW 和 OFF 仍可设置 |
| J25 | PERSIST01-01 回归：career 文档无文件路径（`saveXMLFile` 失败，与游戏一致），正常保存仍为 `COMMITTED`；pass 之后、引擎结束之前为 `WRITTEN`，磁盘 career 仍是上一代标记，T02 开放；保存后继续出售被接受；关闭模式后再存仍 `COMMITTED`；重载 READY 且保留保存后的出售。引擎报 OK 但最终目录账本缺失或参与者混代 → `INCOMPLETE`、T02 关闭、加载 RECOVERY_REQUIRED；随后一次完整保存重新开放 |

全套：

- lupa 默认 Lua 5.5：1273/1273；Lua 5.4：1273/1273。
- Lua 5.1：1264/1264。另有 `test_dealerstock.lua` 因既有的 `read("a")` 问题无法在 5.1 加载，与本批无关。
- 本套在 5.1 下 148/148。

## 10. 未完成 / 未验收

- **未游戏验收**：单机、主机、专服均未执行。建议顺序：
  1. 用测试存档：`rlTradeSaleMode TEST`，做一笔出售，手动保存，退出后重载，用 `rlTradeTxReport` 看 `ledger: READY … load: READY L1`；
  2. 自动保存；
  3. 在保存过程中结束进程（如可行），确认重载时为 RECOVERY_REQUIRED；
  4. 只恢复单个 XML，确认判为混代；
  5. 专服重启；
  6. 客户端中途加入。
- **需在引擎中确认的项**：见第 2 节；以及 `getDate` 和 `io` 是否可用。
- **L3 不支持**：待核对的事务没有自动处理，也没有授权工具。RECOVERY_REQUIRED 只能靠恢复一份完整备份（全部文件）来解除；不能只拷账本，也不能清文件或清锁。
- **门禁覆盖面**：只挡 T02 入口，挡不住旧路径、经销商、HB 加工或其他 mod。
- **数据库外日志**：本批没有独立日志；存档之后的进度随游戏一起丢失（J21）。
- 经济政策、产量、费率、活价、旧订单资产都未改动。

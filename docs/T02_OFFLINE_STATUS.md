# T02 当前状态与验收入口

整理日期：2026-10-14。当前集成基线：RLRM dev `bbb4573`；下述旧测试结果保留原提交归属。

## 当前状态

合同提交、来源移除与恢复、人工/AI活卖资金收据、工资去重、事务持久化与启动恢复、合同诊断均已进入 dev。
原 PR31–34 的开发栈已合入，不再作为待开发或待合入任务。

`rlrm-t02` / `feat/contract-transaction` 是早期工作树，其业务代码仍停在第一批；
本文和测试清单描述当前 dev，不能据此把该旧树打包用于验收。

历史 PR #46 集成验证为 2624/2624，GitHub CI 通过（PR #46）；这是本会话上一轮的验证记录，
本次文档整理没有重跑代码测试。单机、联机主机、专服的游戏内验收均未完成。

## 已实现的边界

- 合同与活卖开关独立，地图加载后回到 OFF；SHADOW 用于观测，TEST 用于复制的测试存档。
- 第四批已经接入存档账本。模式回 OFF 不等于丢弃账本；加载核对后恢复终态去重和未完成事务隔离。
- L1：正常完整保存后重载，保留终态并阻止重复成交；未完成事务保留待核对状态。
- L2：保存失败、缺失或混代文件可检出并限制新的 T02 事务，仍需真实引擎验收。
- L3：没有崩溃后自动补款、退款、复活动物或解锁能力。
- 门禁只覆盖已接入 T02 的入口；不把旧路径、HB 加工及外部 mod 的动作视为已被统一锁定。

## 下一步

按 [T02 游戏验收清单](T02_TEST_WORKFLOW.md)执行：只读冒烟 → 合同 → 活卖与工资 → 保存重载 → 联机与专服。
记录实际测试提交、包哈希、地图/mod/config、前后动物和资金、事务状态、日志及结果。
没有故障注入钩子的异常场景标为阻塞；自动测试通过不代替游戏结果。

## 实施证据

下列 dev 文档包含各批次的历史实现和离线证据，批次内的旧 PR 状态、旧测试总数及“后续批次”描述应按本文的当前集成状态理解：

- [合同适配器实施记录](https://github.com/xtcg/FS25_RealisticLivestockRM/blob/dev/docs/T02_BATCH2_STATUS.md)
- [活卖与工资实施记录](https://github.com/xtcg/FS25_RealisticLivestockRM/blob/dev/docs/T02_BATCH3_STATUS.md)
- [持久化与启动恢复实施记录](https://github.com/xtcg/FS25_RealisticLivestockRM/blob/dev/docs/T02_BATCH4_STATUS.md)
- [活卖专项操作步骤](https://github.com/xtcg/FS25_RealisticLivestockRM/blob/dev/docs/T02_BATCH3_TEST_WORKFLOW.md)（其中“仅内存、不能重载”的第三批限制已由第四批实现取代）

旧开发方案和修正前评审不作为当前状态入口；现有回归测试及实施证据继续保留。

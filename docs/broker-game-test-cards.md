# 商人收购合同：单机游戏内测试卡（BG）

状态：**为尚未在游戏里运行过的构建（0.2.2.2 候选）编写，全部结果为待验证。** 离线回归证明模块和联合 XML，
不证明已安装地图、引擎保存流程或界面。

## 开始前

1. 用存档**副本**测试，不要用唯一一份。记录候选包 SHA-256、地图与模组列表、每月天数（主场景 4 天/月）、本农场资金。
2. 控制台（`~`）命令：`rlBrokerStatus`（只读）、`rlBrokerRecoveryClear`、`rlIdentityStatus`、`rlIdentityRecoveryClear`。
   每步后看 `log.txt` 中 `RLBROKER` 行。
3. 备好至少 2 只自己圈舍里的 Angus 断奶小牛（`rlBrokerStatus` 之外的资格以页面显示为准）。
4. 证据：每张卡结束后保存 `log.txt`，并记录存档目录里 `rm_RlBrokerLive_*`、`rm_RlMarket*` 文件清单。

## BG01 正常成交 → 保存 → 重载
1. 加载副本，打开暂停菜单“设置”页，点击“商人收购合同”。状态应提示先保存一次。
2. 保存一次游戏；`rlBrokerStatus` 应为 `runtime=READY`。
3. 选一只合格 Angus，请求接运报价，15 秒内确认。核对：动物少一，资金增加页面所示净额，三层额度各少一。
4. 保存，退出到菜单，重新加载。通过：动物、资金、剩余额度与保存前一致；`rlBrokerStatus` 为 READY，`mutationAllowed=true`。

## BG02 成交后不保存直接退出 → 暂停 → 恢复
1. 在 BG01 通过后的存档上再成交一只，**不保存**，退出到菜单。
2. 重新加载。预期：Broker 暂停，`rlBrokerStatus` 显示 `runtime=RECOVERY_REQUIRED`，`mutationAllowed=false`（旧购买/出售/移动也被拒绝，这是设计）。
3. 打开 Broker 页面：应出现“恢复收购”按钮（鼠标可点）。点击并确认。
4. 通过：提示已从保存检查点重启；动物和资金仍是上次保存的状态；该只动物的额度回到保存点值；`mutationAllowed=true`；
   存档目录出现 `rm_RlBrokerLive_broker.unsaved.1.xml`（及 `.staging`）。
5. 保存，再看存档目录：`unsaved.1` 文件仍在（后续每次保存都携带）。
6. 控制台等价路径：重复 1–2 后改用 `rlBrokerRecoveryClear`，结果应相同；日志出现 `RLBROKER: recovery cleared`。

## BG03 本会话已成交后拒绝恢复
1. 成交一只（不保存），人为让 Broker 暂停不易复现时，可只验证按钮：成交后 Broker 页面**不应**显示“恢复收购”；
   `rlBrokerRecoveryClear` 返回 `recovery kept: BROKER_NOT_PAUSED` 或 `BROKER_RECOVERY_RELOAD_REQUIRED`。
2. 通过：任何情况下都不改动 WAL、不放开旧渠道。

## BG04 身份恢复后自动解除
前提：身份账本处于 RECOVERY_REQUIRED 且存档有 Broker 证据（可借经销商 G10b 的构造）。
1. 加载。预期：`rlBrokerStatus` 显示 `disabled=BROKER_IDENTITY_NOT_READY hold=true`，旧购买/出售被拒。
2. 执行 `rlIdentityRecoveryClear`。通过：不重启游戏，数秒内 `rlBrokerStatus` 变为 READY（或明确的其他原因），`hold=nil`。
3. 在保持期间保存一次再重载：不应出现永久的 `BROKER_RECOVERY_CARRIED:ASSETS:BROKER_IDENTITY_NOT_READY`。

## BG05 首次保存前的未来需求
1. 新档（无 Broker 保存点），推进一到两个月后打开 Broker 页面（生成需求），记录订单号，**不保存**退出。
2. 重新加载并打开 Broker 页面。通过：不进入时钟回退暂停；回到该月时订单号与之前一致（未重抽）。

## BG06 暂停期间保存后的拒绝
1. 在 BG02 步骤 2 的暂停状态下保存一次，再退出重载。
2. 通过：`rlBrokerRecoveryClear` 返回 `recovery kept: …`（检查点无法证明），旧渠道保持关闭；日志保留证据。这是资金归属不明的设计行为，不是缺陷。
3. 记录此时存档目录文件清单，供设计“放弃 Broker 证据并重建基线”流程时使用。

## 失败时请带回
`log.txt` 中所有 `RLBROKER`、`Broker unavailable`、`Broker save paused` 行；`rlBrokerStatus` 输出；存档目录中
`rm_RlBrokerLive_*`、`rm_RlMarket*`、`careerSavegame.xml` 里的 `rlBrokerRecovery` 属性值。

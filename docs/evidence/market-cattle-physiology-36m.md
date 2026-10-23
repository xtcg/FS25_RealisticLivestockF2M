# 牛候选条件的生理测量

机器结果：[market-cattle-physiology-36m.json](market-cattle-physiology-36m.json)。复现命令：

```sh
python3 tests/marketreachability.py --output /private/tmp/market-cattle-physiology-36m.json
```

本次完成 28 个各 36 游戏月的离线场景：仓库 animals.xml 的 7 个公牛 subtype × 新营养/旧营养路径 × 未阉/阉割；基因均为 1，出生因子 1，每月 1 天，每小时采样。7 个 subtype 包括带 requiredDLC 声明的 Highland；这里只证明仓库定义可被模型运行，不证明用户当前地图或 DLC 已安装该品种。没有新增代理品种或调整生长曲线。

场景使用现有 FeedSim 的引擎替身、HB 1.5 食物组、持续可用 TMR 与犊牛奶和自动饮水。FeedSim 设置的健康恢复/下降参数 10/25、阈值 .45 明确记录在每个场景；无疾病挑战。本报告不验证地图实际饲料组、游戏内健康参数、食物价格、最终付款、保存或联机。累计饲料体积来自真实 removeFood 调用，没有将补充槽容量误算成消耗，也没有把未知饲料成本视为免费。

84 组“场景 × 包”中，56 组在已知条件下有重叠采样窗口，28 组架子牛包在本次 TMR 饲养路径下没有重叠窗口。这不是对所有日粮、遗传或慢熟扩展包的不可达结论。没有为产生窗口而放宽 80% Wref 或 finish < 65 门槛。

**完整资格通过为 0，生产准入为 false。** 尚缺最低采购公斤数、实际最低年龄、发育就绪/成品分类、经济标准参考体重/对应屠宰 basis 等配置或能力；这些条件保留 UNKNOWN。`measuredWindows` 只代表当次已知检查未失败，`completeWindows` 才代表全部资格通过，两者不能互换。本报告类型为 `PHYSIOLOGY_MEASUREMENT_ONLY`，不能冒充月需求目录要求的 `MODEL_REACHABILITY`，U51 尚未完成。

结果包含完整包 revision 和实际载入代码/XML 的 SHA-256；加载记录覆盖 stubs 启动时载入的生长、营养和体况核心，运行结束逐一复验，避免并行开发期间静默混用版本。源代码哈希是本次文件集合的证据，报告内 commit 是执行开始时的仓库 HEAD，未声称当时所有测量工具已提交。

# 《断链》BREAK THE CHAIN
## 落地可行性评估与补充规范 V1.1-draft

> **评估对象**：`断链_BREAK_THE_CHAIN_Game_Design_Bible_V1.0.md`（下称 GDB）、`断链_BREAK_THE_CHAIN_视觉圣经_V1.0.md`（下称 VB）  
> **编制日期**：2026-10-24  
> **文档性质**：对两份 V1.0 圣经的**审查意见 + 补充规范**。不直接改写原文；本文中标为 `PROPOSED` 的条目需要产品负责人拍板后再合入 GDB/VB V1.1。  
> **证据等级**：`SIM` = 本文蒙特卡洛模拟得出；`PLATFORM` = 已核对的 Roblox 官方/开发者论坛信息（见第 11 章）；`JUDGEMENT` = 经验判断，需试玩验证。  
> **合入状态（2026-10-24）**：§9 的 D1–D9 与 §4 不一致清单已按推荐方案合入 `断链_BREAK_THE_CHAIN_Game_Design_Bible_V1.1.md` 与 `断链_BREAK_THE_CHAIN_视觉圣经_V1.1.md`（V1.0 原稿保留）。D4 的落地口径：真人 ≥4 名为正式局，不补 Bot；真人 1～3 名时 Bot 补位到 6 名参与者进行练习局，不发正式奖励。§5 工程补充规范也已合入 GDB V1.1：5.1→§17.6，5.2→§9.5，5.3→§20.9，5.4→§19.5，5.5→§24.4，5.6→§9.6，5.7→§20.10，5.8→§20.2，5.9→§22.7，5.10→§18.7，§3.8 读条计时→§21.2，§10 Prompt 补丁→§26.4。**尚未合入**：§6 修订路线中的 Gate 0 / A0，以及 §7、§8 的资源估算与风险登记表。

---

# 0. 结论摘要

**总体判断：值得做，但要先改几处设计，再动手写代码。**

| 维度 | 评级 | 一句话理由 |
|---|---|---|
| 技术可行性（Roblox 引擎 + Luau） | **高** | 感染森林、单写者事务、服务端权威在 Roblox 上都是常规做法；2026 年官方 Server Authority 已正式发布，移动作弊防护的成本也降低了 |
| 文档完整度 | **高** | 状态机、不变量、测试矩阵、Gate、砍项标准都很完整，在独立游戏里少见 |
| 核心玩法成立的风险 | **中高** | 模拟显示，"断链"只有在 **≥8 人且感染过半**时才稳定出现；零号的技术强弱会大幅改变树的形状（§3.2） |
| 隐藏信息（潜伏期）的可实现性 | **低** | 按现有规则，扑咬特效、解药掉落和 Roblox 引擎默认复制都会泄露潜伏身份（§3.1） |
| 冷启动 / 人数 | **高风险** | 新游戏凑齐 4 名真人本身就难，中途加入者还要空等最多 8 分钟（§3.4） |
| 单人 + AI 开发的工作量 | **中** | 玩法代码可控；最贵的是**组织 16～24 名真人测试**和**角色美术**（§3.5、§7） |
| 市场与变现 | **中** | 中国大陆没有官方运营的 Roblox，主要玩家在海外，要以英文为主（§3.9）；Creator Rewards 的收益按留存发放，正好契合"短局、连续重开" |

**建议的最小改动**（详见 §9 决策清单）：

1. P0 关闭潜伏期的"保密"部分，只保留一个**公开的 3～5 秒尸变过渡**；完整保密作为 EXPERIMENT 推后。
2. 给零号加平衡杠杆（例如扑咬冷却 ×1.5），把感染压力推到子节点上，从而产生可治愈的枢纽。
3. 扫描分级（SINGLE/BRANCH/HUB）从绝对人数改为**相对当前感染规模**。
4. 引入 `ParticipantId` 抽象和 **Bot 补位**，同时解决冷启动和 24 人压测两个问题。
5. Gate A 的验收人数从"4 人"改为"**8 人（可含 Bot）**"：4 人局在数学上就不会出现断链，用它验证核心特色没有意义。
6. 角色方案定为**使用玩家自己的 Roblox Avatar + 感染叠加层**，而不是自制写实角色模型。

---

# 1. 两份文档做得好的地方（保留，不要改）

- **决策分层**（LOCKED / BASELINE / EXPERIMENT / FUTURE）和"玩法优先于视觉"的冲突规则，适合交给 AI Agent 执行。
- **感染树的 10 条不变量 + G-01～G-18 测试**，把最容易出 bug 的部分前置成了属性测试。
- 用 `infectionEpisodeId` 而不是 UserId 作父指针，正确处理了"治愈后再感染"的问题。
- **退出规则**（虚拟根、稳定上游重挂、断联倒计时继承）堵住了"退局 = 免费解药"的漏洞。
- **防提前判负**（存在 UNSTABLE/INCUBATING 时不立即判丧尸胜）。
- **Studio 只能模拟 8 个客户端，不等于 24 人通过**这一点写得很清楚。
- 第 28 章的 CONTINUE / PIVOT / STOP 砍项标准。

---

# 2. 评估方法

1. 通读两份文档，检查内部逻辑、两文档之间的一致性，以及与 Roblox 引擎行为的冲突。
2. 用一个简化的蒙特卡洛模型模拟感染树形状（§3.2）。
3. 对不确定的平台事实做了联网核对（§11）。核对时发现，有两条我原先的印象已经过时：Highlight 上限已从 31 提高到 255；Server Authority 已于 2026 年 7 月正式发布。

---

# 3. 关键问题（按严重度排序）

## 3.1 【P0】潜伏期"保密"在规则层和引擎层都会泄露

GDB §7.3 和 VB §3.4 要求潜伏者对其他人类"看起来完全是人类"。但现有规则自己就在公开这个信息：

| 泄露源 | 出处 | 说明 |
|---|---|---|
| `VFX_BITE` 扑咬特效 + 音效 | VB §4.2 | 附近所有人都能看到谁被咬了 |
| 攻击者与被感染者之间的红色脉冲 | VB §4.1 | 公开暴露了**谁感染了谁**，也就是树的拓扑 |
| 持有解药者被感染后，解药掉落 | GDB §10.1 | 解药掉在地上 = 公告"此人已感染" |
| 潜伏者无法修电力、无法拿解药 | GDB §7.3 | 交互失败本身就是信号 |
| 扑咬前摇 0.35 秒 + 目标短暂受击 | GDB §9.2 | 动作在所有客户端上复制 |

Roblox **引擎默认复制**也会泄露，见 §5.1 的"泄密面清单"（Team、Attributes、Humanoid 属性、Tool 等）。

**结论**：在 5 秒窗口里，被咬这件事本身几乎总是公开的，"潜伏保密"带来的玩法收益很小，却要求整套权限系统和大量 QA。

**建议（PROPOSED）**：

- **P0**：`EnableIncubation=true` 但 `IncubationSecret=false`。被咬后进入 **3～5 秒的公开尸变过渡**（可见的半异化外观，不能攻击/交互，可以移动），然后成为 INFECTED。这样保留了"刚才的队友变了"的戏剧性，也去掉了泄密风险。
- 解药在**公开尸变时**掉落，而不是被咬瞬间。
- 红色感染脉冲只给攻击者和受害者本人看，或者干脆去掉。
- 完整保密版作为 `EXP-01b`，等 Gate B 之后、在核心玩法已经成立的前提下再验证。
- **权限系统仍然必须做**：感染树拓扑、扫描结果、断联重连目标依然是秘密信息，§5.1 的清单照样适用。

## 3.2 【P0】感染树的形状：断链是否真的会经常发生（SIM）

**模型**：N 名玩家，每名玩家的"追击能力"服从对数正态分布（σ 越大，技术差距越大）；每次感染时，按能力加权选出一名稳定丧尸作为扑咬者，受害者从人类中随机选取。统计感染比例达到 50% / 75% 时：是否存在 branchImpact ≥ 4 的可治愈节点（HUB）、一针最多能切掉多少感染者、根节点直接感染的比例。每组 3000～4000 次。脚本见附录 A。

| N | 根数 | 感染比例 | 零号是否为技术最强者 | P(存在 HUB≥4) | 最优一针切掉的感染者比例 | 根直接感染占比 |
|---:|---:|---:|---|---:|---:|---:|
| 6 | 1 | 75% | 否 / 是 | **0.00 / 0.00** | 0.54 / 0.41 | 0.61 / 0.78 |
| 8 | 1 | 50% | 否 / 是 | **0.00 / 0.00** | 0.54 / 0.41 | 0.62 / 0.79 |
| 8 | 1 | 75% | 否 / 是 | 0.50 / **0.15** | 0.58 / 0.41 | 0.46 / 0.67 |
| 12 | 1 | 75% | 否 / 是 | 0.84 / **0.46** | 0.61 / 0.40 | 0.34 / 0.57 |
| 16 | 2 | 50% | 否 / 是 | 0.44 / **0.09** | 0.43 / 0.28 | 0.53 / 0.76 |
| 24 | 2 | 50% | 否 / 是 | 0.82 / **0.33** | 0.46 / 0.27 | 0.40 / 0.67 |
| 24 | 2 | 50% | 否 / 是（σ=1.5） | 0.81 / **0.13** | 0.50 / 0.20 | 0.40 / 0.81 |

**解读**：

1. **4～7 人档在数学上不会出现 HUB**，最多只有 BRANCH。这一档本质上就是经典感染模式。这可以接受，但**不能用 4 人局来验证核心特色**，Gate A 的验收需要改。
2. **零号的技术水平是最大的变量**。零号如果是全场最强的玩家，就会自己咬掉大部分人，树变成"星形"：根不可治愈，子节点全是叶子，断链形同虚设。24 人局中 HUB 出现率可能从约 80% 降到 13～33%。
3. **反方向的风险同时存在**：HUB 一旦存在，最优一针平均能切掉 40～60% 的感染者。8 秒重连能否真正挽回，决定了这会不会变成"一针定胜负"。
4. **重连也会让树变平**：GDB §8.5 允许重连到根。断联者自然会就近或优先接到根上，长期看树会越来越扁。这是可以接受的涌现策略，但会进一步降低 HUB 的出现频率。

> 局限：模型没有模拟空间位置、治愈与重连的动态过程，也没有模拟玩家刻意保护枢纽的行为，只用来判断方向，不代表真实数值。

**建议的平衡杠杆（PROPOSED，均为 BalanceConfig 可调项）**：

| 杠杆 | 建议起点 | 作用 |
|---|---|---|
| `RootBiteCooldownMultiplier` | 1.5 | 把感染工作推给子节点，产生可治愈的枢纽 |
| `RootRelinkHoldMultiplier` | 1.5（重连到根需要 1.5 秒） | 减缓"全员挂根"导致的树扁平化，同时保留跨树重连 |
| 扫描分级相对化 | SINGLE = 1；BRANCH = 2 至 HUB 阈值；`HUB ≥ max(3, ceil(0.2 × 当前公开感染者数))` | 让 8～15 人档也能出现"关键枢纽" |
| 零号选择偏置（保底/随机零号时） | 优先从本局"上一局未当过零号"的玩家中选；**不按技术选** | 减少"高手当零号"带来的星形树 |
| 新埋点 | `tree_shape_snapshot`：每 30 秒记录最大可治愈分支、根直接子节点占比 | 用真实数据代替本模型 |

## 3.3 【P0】Gate A 的"4 人闭环"验证不了核心特色

GDB §25 Gate A 要求"4 人完成被感染—治愈—断联—重连—结算闭环"。按 §3.2，4 人局最多出现 `A→B→C` 这样的 3 层链，治愈 B 只能让 C 一个人断联。闭环在技术上能跑通，但验证不了"断链值得争夺"这一支柱。

**建议（PROPOSED）**：

- **Gate A**：技术闭环用 4 人 + 脚本化场景（G 系列测试）验证；**玩法验证至少要 8 名参与者**（真人加 Bot 补位）。
- **Gate B** 的真人测试至少要有 2 场 10～12 人的场次。
- 在 GDB §5.1 中明确写出：**4～7 人档是"经典感染 + 小规模治愈"体验，断链是 8 人以上的特色。** 宣传素材只用 12 人以上的局录制。

## 3.4 【P0】冷启动与人数：最可能直接导致项目失败的因素

这不是设计缺陷，而是 Roblox 新游戏的现实：**上线初期，同时在线人数可能只有个位数。**

| 问题 | 现状（GDB） | 后果 |
|---|---|---|
| 正式局需要 4 名真人 | §5.1 | 在线 1～3 人时玩家只能在练习区干等，然后离开 |
| 对局中加入 → 隔离区等下一局 | §5.2 | 最长要等 8 分钟以上，几乎一定流失 |
| 24 人压测只能靠真人 | §21.5 | 单人开发者很难反复组织 24 人 |
| Roblox 的推荐算法依赖留存和时长信号 | 平台机制 | 早期流失 → 曝光更少 → 人更少，形成恶性循环 |

**建议（PROPOSED）**：

1. **`ParticipantId` 抽象 + Bot 补位**（§5.3）。开局时真人少于 `BotFillTarget`（建议 6）就由 Bot 补足。Bot 在 UI 上明确标为 Bot；**有 Bot 参与的局不发放正式战绩奖励，或者降低奖励**。这样既保证了"1 名真人进来也能玩"，也让 24 人压测可以用"8 真人 + 16 Bot"来近似。
   - 注意：这和 LOCKED 第 6 条"人数不足也能开局"并不冲突；和 BASELINE "绝不回填"的冲突只在对局**进行中**，Bot 只在**开局时**补位。
2. **中途加入规则**（替换 GDB §5.2 的"隔离区等待"）：
   - 开局 60 秒内加入 → 作为 HUMAN 进入本局，冻结的人数档参数不变。
   - 开局 60 秒后加入 → 作为 **INFECTED 叶子**挂到当前存活的根（或 VirtualRoot）下，立即可以游玩；不计"感染他人"类奖励。
   - 最后 90 秒（撤离期）加入 → 观战本局，结算后进入下一局。
   - 标为 `EXP-07`，与"隔离区等待"做 A/B。
3. **测试招募计划**：建立 Discord 社区和 Roblox Group，固定每周 1～2 次"测试之夜"。按经验，到场率约为报名人数的一半左右（JUDGEMENT），所以想凑 16～24 人，需要 30～50 人报名。

## 3.5 【P0】缺少"角色方案"决策：自制写实角色 vs 玩家 Avatar

VB §3.2 和 §11 按"自制风格化半写实角色"编写概念图 Prompt，并给出 4k～10k 三角面的自制网格预算；同时 VB §3.1 又要求"保留玩家发型、面部"，GDB §0.3 写的是"Roblox Avatar 适配优先"。这两个方向是互斥的：**每个玩家的 Avatar 都不同，无法为它们逐一制作"感染版"模型。**

**建议（PROPOSED）**：P0 使用**玩家自己的 R15 Avatar**，感染效果做成通用叠加层。

| 层 | 做法 |
|---|---|
| 体型公平 | 进入对局时通过 `HumanoidDescription` 把身高/宽度等缩放夹在固定区间内；判定使用**服务端固定胶囊体**，与 Avatar 网格无关 |
| 配件 | 对局中隐藏超大配件（翅膀、背部大件等），保留头发和面部配件，维持"熟人异化" |
| 感染外观 | BodyColors 向灰绿方向偏移、红色裂纹贴花或贴合式配件、`Highlight` 轮廓（上限已提高到 255，但每个 Highlight 都有渲染成本，只给公开状态的角色使用）、**丧尸动画包**（前倾跑、扑咬） |
| 断联外观 | 金色碎裂环（Billboard 或粒子）+ 顿挫动画 + 世界空间倒计时 |
| 自制"幸存者服装" | 降级为 P2 外观商品，不是 P0 前置条件 |

收益：美术工作量下降一个数量级，"认得出原来的朋友"这一支柱反而更容易实现。代价：画面风格的统一程度降低，需要在方块风、Rthro 等多种体型上分别验证状态的可读性（加入 VB §13.3 截图矩阵）。

## 3.6 【P1】扑咬命中与网络延迟：缺少具体的补偿规范

GDB §9.2 和 §20.4 只写了"必要的延迟容忍"。在手机网络下（往返 100～250 ms），追击者在自己屏幕上"咬到了"但服务端判定没咬到，是这类游戏最常见的差评来源。

**补充规范见 §5.2。** 关于平台能力：Roblox Server Authority 已于 2026 年 7 月正式发布，可以从引擎层面防住加速、穿墙等物理作弊；但官方明确表示**服务端回溯（server-side rewind）命中判定仍在开发中**，所以扑咬命中仍需自己做位置历史和容差判定。

## 3.7 【P1】扫描结果和重连方向提示由客户端过滤遮挡，会变成透视

GDB §12.3 写的是"服务端授权返回范围及粗分类，由客户端按当前可见性/合理遮挡渲染"。数据一旦发给客户端，作弊者就能无视遮挡把它全部显示出来。这和 GDB §17.2 的"只发送客户端有权知道的数据"相矛盾。

**建议**：遮挡判断放在**服务端**（从扫描者头部向目标做射线检测，或使用预先烘焙的区域可见性表），只下发通过检测的目标。另一种做法是在设计上接受"扫描半径内可以穿墙"，在规则中写明，这样就不存在"泄露"。二者选一，不要依赖客户端隐藏。

## 3.8 【P1】读条交互（解药、重连、电力、撤离）必须由服务端计时

如果用 `ProximityPrompt.HoldDuration` 实现读条，按住多久是**客户端**判断的，作弊工具可以直接触发 Prompt 的完成事件。

**规范**：服务端在收到 `HoldBegan` 时记录开始时间和状态版本，每个 Heartbeat（或每 0.1 秒）重新校验距离、状态和视线；只有在服务端累计时间 ≥ 所需秒数时才提交。`Triggered` 事件只能当作"意图"，不能当作完成的证据。

## 3.9 【P1】市场定位：首发语言应为英文

中国大陆目前没有官方运营的 Roblox 版本，Roblox 的主要玩家在北美、拉美、东南亚和欧洲。GDB/VB 的中英双语规划方向正确，但需要明确：

- **商店页、缩略图文案、局内 UI 以英文为主**，并接入 Roblox 自动翻译和 LocalizationTable；第二批语言建议西班牙语、葡萄牙语（巴西）、印尼语、菲律宾语、泰语（JUDGEMENT，以 Analytics 的地区分布为准）。
- 不要把中文"断链"作为唯一的品牌标识；`BREAK THE CHAIN` 上线前要在 Roblox 内搜索查重。
- 收款方面：按开发者所在地核实 DevEx 资格、税务表格和收款通道，以及 Creator Rewards 要求的**身份验证账号**。

---

# 4. 两份文档之间的不一致清单

| # | GDB | VB | 建议的统一处理 |
|---|---|---|---|
| 1 | 没有生命值，一次有效扑咬即感染（§9.2） | HUD 有"生命/被攻击反馈""生命/耐力信息"（§7.1、§7.2） | 删除"生命"，只保留**耐力**和**受击反馈** |
| 2 | 状态枚举 `UNSTABLE`，没有 CURED 主状态 | 文字和图标用 `DISCONNECTED`、`CURED`、`RECONNECTED`（§2.3、§7.5） | 建立"代码枚举 → 显示文案"映射表：`UNSTABLE→DISCONNECTED/断联`；`CURED` 和 `RECONNECTED` 是**事件**，不是状态 |
| 3 | 最低开局人数已定为 4（§29） | §15 仍写"待定" | VB V1.1 同步 GDB §29 的答复表 |
| 4 | Roblox 服务树式目录（§20.2），`Tests/` | `src/shared/...`、`docs/visual-bible.md`（§10.3） | 统一为 §5.8 的 Rojo 目录 |
| 5 | "Roblox Avatar 适配优先" | 自制写实幸存者角色 Prompt、4k～10k 三角面预算 | 按 §3.5 决策 |
| 6 | 潜伏期对他人保密（§7.3） | `VFX_BITE` 公开、感染时红色脉冲连线（§4.1、§4.2） | 按 §3.1 处理 |
| 7 | 扫描结果由客户端过滤遮挡（§12.3） | 远距离"用合规方向提示替代透墙"（§4.1） | 统一由服务端过滤（§3.7） |
| 8 | §0.3 写 `PreparationSeconds`，§24.2 写 `PrepareSeconds`；`MaxNPCCrowdSeed`、`DefaultPerspective` 没有出现在配置示例中 | — | 以 BalanceConfig 为唯一来源，文档表格从配置生成或手动对齐 |
| 9 | 人类胜利条件 2"感染被遏制"：根不可治愈，实际上只有根离线时才可能触发 | — | 在 §13.3 注明这是**边界兜底条件**，不是可追求的策略，避免新手误解 |
| 10 | 扫描分级为绝对人数（1 / 2～3 / 4+） | VB §4.1 只写"简化的下游规模" | 改为相对分级（§3.2） |

---

# 5. 补充规范（建议合入 GDB 第 17、20、21 章）

## 5.1 Roblox 引擎层"泄密面"清单（QA 必查）

只要秘密状态（潜伏、感染树拓扑、扫描结果）**改变了下列任何一项，就等于向所有客户端广播了它**：

| 引擎面 | 风险 | 规定 |
|---|---|---|
| `Player.Team` / `TeamColor` | 默认玩家列表和名牌颜色都会显示 | 不用 Teams 表示阵营；如果要用，只在**公开转换**时修改 |
| `Instance:SetAttribute`（Player、Character 上） | 属性复制给所有客户端 | 角色上只放公开状态；秘密数据只存在服务端内存中 |
| `Humanoid.WalkSpeed`、`JumpPower`、`DisplayName`、`HealthDisplayType` | Humanoid 属性会复制 | 秘密状态期间不修改；速度差异只在公开转换后生效 |
| `Tool` / Backpack | 装备中的 Tool 对所有人可见 | 能力输入用 `ContextActionService` 自定义，不用 Tool |
| `leaderstats` | 默认排行榜公开 | 只放公开统计 |
| 动画轨道和音效 | 在角色上播放会被复制 | 秘密阶段不播放阵营专属动画和音效 |
| `CollisionGroup`、零件属性 | 复制 | 只在公开状态下切换 |
| `ReplicatedStorage` 中的任何对象 | 所有客户端可读 | 不放局内秘密数据 |
| `Highlight`、`BillboardGui` 挂在角色上 | 服务端创建的会复制给所有人 | 私有标记**由客户端本地创建**，内容来自 `FireClient` 的定向数据 |
| `FireAllClients` | 广播 | 公开事件只携带公开字段；私有事件一律 `FireClient` |

**QA 方法**：在测试版本中提供一个开发者面板，以"人类客户端"视角列出该客户端能读到的所有 Attributes、Team 和收到的 Remote 载荷，与权限矩阵（GDB §17.2）逐项比对。

## 5.2 扑咬判定与延迟补偿规范

| 项 | 规范（起点值，进入 BalanceConfig） |
|---|---|
| 位置历史 | 服务端为每个参与者的 HumanoidRootPart 维护 **1 秒环形缓冲**，按 20 Hz 采样 |
| 回溯时间 | `rewind = clamp(attacker:GetNetworkPing(), 0, 0.25)` 秒（`GetNetworkPing` 的语义以官方文档为准）；取目标在 `now - rewind` 时刻的插值位置 |
| 判定 | 回溯位置与攻击者当前位置的距离 ≤ `BiteRange + BiteTolerance`；目标在攻击者朝向 ±70° 锥内；中间无静态遮挡（射线检测只针对地图静态碰撞组） |
| 起点数值 | `BiteRange = 5.5 studs`（两根部中心距离），`BiteTolerance = 1.5 studs` |
| 时序 | 客户端在前摇结束时发出 `TryBite`；服务端校验 `now - lastBiteAt ≥ cooldown` 和前摇窗口；同一前摇只接受一个请求 |
| 手机辅助 | 客户端自动选取锥内最近的合法目标作为 `targetHint`，服务端仍独立复核 |
| 争议记录 | 判定失败但距离在 `Range + 2 × Tolerance` 以内时，记录 `bite_near_miss`，用于调参 |
| 与 Server Authority 的关系 | Server Authority 负责移动合法性（防加速、穿墙）；扑咬判定仍按本节执行。启用前在 Studio 中验证"阵营转换不重生、不重新挂载角色"的流程（论坛报告过角色重新挂载后客户端一直回滚的问题） |

## 5.3 参与者抽象与 Bot

把 GDB §20.3 的 `userId: number` 改为：

```lua
type ParticipantId = string -- "U:<userId>" 或 "B:<botIndex>:<roundId>"
type Participant = {
    id: ParticipantId,
    kind: "Player" | "Bot",
    player: Player?,       -- 仅真人
    character: Model?,
}
```

- `InfectionGraphService`、`PlayerStateService`、`RoundService` **只认 ParticipantId**，不直接引用 `Player`。纯逻辑测试和 Bot 因此可以共用同一套代码。
- **Bot 行为（P0 只做到够用）**：
  - 人类 Bot：去最近的未完成电力节点 → 遇到威胁就沿预计算的路点逃离 → 撤离窗口开启后前往出口。
  - 丧尸 Bot：追击视野内最近的人类 → 断联时前往最近的稳定感染者重连。
  - 路径：优先使用关卡中手工摆放的路点图，`PathfindingService` 作为兜底；服务器上的 Bot 数量 ≤ 18。
- **Bot 不触发**任何持久化奖励、排行榜或每周挑战进度；结算页公开标注 Bot。
- **压测用途**：在 Studio 中用 8 个本地客户端 + 16 个 Bot 近似 24 人局，测量服务端事件处理和广播字节数（客户端渲染压力仍需真机验证）。

## 5.4 Roblox 回合循环必须处理的"非设计"事件

GDB 中没有覆盖以下几项，但每个 Roblox 回合制游戏都会遇到：

| 事件 | 规定 |
|---|---|
| 玩家点击菜单中的"重置角色" | `StarterGui:SetCore("ResetButtonCallback", false)` 禁用；服务端仍需处理 Humanoid 死亡 |
| 掉出地图 / 卡死 / 意外死亡 | 在最近的安全点重新生成，**保持当前阵营与图状态不变**，并清除进行中的读条 |
| `CharacterAutoLoads` | 由 RoundService 控制生成时机，阵营转换时**不重新生成** |
| 回合重置时的资源泄露 | 每局创建的连接、计时器、实例统一用清理器（Trove/Janitor 一类模式）在回合结束时释放；GDB 测试 R-12"连续 50 局"中加入**服务端内存曲线**检查 |
| StreamingEnabled | 远处角色可能没有流式加载到客户端。世界空间提示（重连方向、扫描标记）由服务端计算并下发坐标或方向；角色模型的流式模式设为 `Persistent` 或 `Atomic`，并评估内存影响 |
| 服务器关闭（版本更新） | `game:BindToClose` 中尽力保存奖励数据，不尝试持久化对局状态 |

## 5.5 灰盒起步数值（仅用于 Gate A0/A，不是平衡结论）

GDB 有意不写死速度。但灰盒阶段需要一组起点，否则各模块只能各自猜测：

| 参数 | 起点 | 备注 |
|---|---:|---|
| 人类步行 | 16 studs/s | Roblox 默认值 |
| 人类冲刺 | 23 studs/s，最多 5 秒；耐力恢复速度为消耗的一半 | |
| 稳定丧尸奔跑 | 18 studs/s | 略快于人类步行，慢于冲刺 |
| 丧尸扑击 | 前摇 0.35 秒后 0.25 秒内冲刺约 9 studs | 未命中有 0.6 秒后摇 |
| 断联丧尸 | 17 studs/s，可短冲刺，不能咬人 | |
| 治愈 / 重连 / 电力交互半径 | 8 / 8 / 7 studs | 服务端判定 |
| 撤离区 | 直径约 16 studs，读条 2 秒 | |
| 扫描半径 | 50 studs | GDB 给的范围是 40～60 |
| 地图可玩区（SMALL / MEDIUM / LARGE） | 约 180×180 / 260×260 / 360×360 studs | 目标是 15～30 秒内能再次遭遇 |
| 走廊 / 门洞 | 宽 ≥ 10 studs / 门宽 ≥ 6、高 ≥ 9 studs | 需在 Rthro 高大体型上复核 |

## 5.6 输入与镜头

- PC：默认第三人称，提供 Shift Lock；扑咬朝向取镜头方向。
- 手机：右下角扑咬/交互大按钮；交互对象自动选取（最近、可见、合法）；读条期间按钮显示环形进度。
- 手柄：P0 不宣传支持（GDB §17.3 已写）。

## 5.7 工程工具链（GDB §20 没有具体选型，这里给出建议）

| 用途 | 建议 | 说明 |
|---|---|---|
| 工具链版本管理 | Rokit | 锁定以下工具的版本 |
| 文件同步 | Rojo 7 | Git 作为唯一来源，Studio 只做运行和摆放场景 |
| 包管理 | Wally | |
| 格式化 / 静态检查 / 类型 | StyLua、Selene、luau-lsp（`--!strict`） | 在 CI 中执行 |
| 纯逻辑单元测试 | **Lune** 在本地/CI 运行 InfectionGraph 等纯 Luau 模块 | 对应 GDB §20.2"在 Roblox 环境以外测试"的要求 |
| 引擎内测试 | Jest-Lua（`roblox/jest`） + **Open Cloud Luau Execution API** | 官方 `place-ci-cd-demo` 给出了"Selene → StyLua → Rojo 构建 → 上传测试 Place → 云端执行测试"的参考流程；单任务最长约 5 分钟，有并发限制 |
| AI 辅助操作 Studio | Studio **内置 MCP Server** + 官方 `roblox-studio-agent-plugin` | 支持 Claude Code 连接，可以执行 Luau、修改属性、启动测试，适合搭场景和做冒烟测试 |
| 持久化 | ProfileStore（会话锁定）或自写带会话锁的 DataStore 封装 | GDB §18.5 要求防重复发放 |
| 网络层 | 先用原生 `RemoteEvent` + 统一校验层；需要压缩时再评估 Zap/Blink 等代码生成器 | 非 P0 |

> AI Agent 约束补充：Agent 通过 Studio MCP 修改的场景内容必须回写到 Rojo 管理的文件或 `.rbxm` 资源中，**不允许只存在于某个 Studio 会话里**。

## 5.8 统一的 Rojo 目录（合并 GDB §20.2 与 VB §10.3）

```text
break-the-chain/
├── docs/                     # 两份圣经 + 本文 + ADR（决策记录）
├── art/                      # VB §10.3：concepts / source-blender / exports / vfx
├── src/
│   ├── shared/               # → ReplicatedStorage/Shared（Constants, BalanceConfig, Types, VisualTokens, PublicEventTypes）
│   ├── server/               # → ServerScriptService/Game（GDB §20.2 全部 Service）
│   │   └── logic/            # 纯逻辑：InfectionGraph、状态机、胜负判定（不依赖 Roblox API，可在 Lune 中运行）
│   ├── client/               # → StarterPlayerScripts/Controllers
│   └── assets/               # → ServerStorage/GameAssets（.rbxm）
├── tests/
│   ├── lune/                 # 纯逻辑属性测试 G-01～G-18、R 系列
│   ├── engine/               # Jest-Lua 引擎内测试
│   ├── screenshots/  perf/  visual-regressions/
├── sim/                      # 平衡模拟脚本（附录 A 的升级版）
├── default.project.json      # Rojo
├── rokit.toml  wally.toml  selene.toml  stylua.toml
└── .github/workflows/        # lint → lune 测试 → 构建 → 云端引擎测试
```

## 5.9 埋点落地

- 新手漏斗、进度和经济使用 Roblox 原生 `AnalyticsService`（漏斗事件、自定义事件），可以直接在 Creator Analytics 中查看。**自定义事件名和字段数量有上限**，GDB §22.2 的 14 个事件需要合并字段后再接入；具体上限以官方文档为准。
- 对局级详细日志（树形状快照、未命中扑咬）：调试环境输出到 Studio；正式环境如需接入外部服务，用 `HttpService` 批量上报，注意每个服务器的请求频率限制，**不要上报任何个人信息或聊天内容**。

## 5.10 变现补充（P0 仍然不接内购）

- **Creator Rewards**（2025 年 7 月起取代 Engagement-Based Payouts）：活跃付费用户每天在某个体验中停留满 10 分钟，且该体验是其当天最先打开的三个之一时，创作者获得固定 Robux。这意味着**"当天第一个打开"和"每天回来"比单次时长更重要**，直接支持本作"短局、连续重开、每日挑战"的设计方向。
- 每日挑战（GDB §18.6）应从 P2 提前到 Gate D：它是 Creator Rewards 时代最便宜的回访驱动。
- 其他条目维持 GDB §18 的非 P2W 原则。

---

# 6. 修订后的开发路线（PROPOSED，替换 GDB §25 的前半段）

> 时间按**单人全职 + AI 辅助**粗略估算（JUDGEMENT）；兼职请乘以 2～2.5。

| Gate | 内容 | 估时 | 通过条件 |
|---|---|---:|---|
| **0 · 决策与脚手架** | 拍板 §9 决策；Rokit/Rojo/CI 脚手架；把附录 A 的模拟升级为带空间因素的版本 | 1 周 | CI 能跑 Lune 测试；决策写入 ADR |
| **A0 · 纯追逐原型** | 只有人类/丧尸、扑咬、冲刺、一张灰盒小图、Bot；**没有治愈和树** | 1～2 周 | 验证 FAST 支柱：不加断链，追逐本身是否好玩（GDB §28.1 问题 1） |
| **A · 规则闭环** | 感染森林、治愈、断联、重连、退出、胜负；G/R 系列测试全部通过 | 3～4 周 | 8 名参与者（可含 Bot）连续 20 局无不变量失败 |
| **B · 可玩 Alpha** | 完整灰盒地图、扫描、电力、撤离、手机 HUD、Avatar 感染叠加层 | 4～6 周 | **至少 2 场 10～12 人真人测试**；多数人能复述"救枢纽 → 断联 → 重连" |
| **C · 规模 Beta** | 16～24 人（真人 + Bot）、低端机性能、美术垂直切片、截图回归 | 4～6 周 | GDB §25 Gate C 条件 |
| **D · 软启动** | 英文商店页、新手漏斗、每日挑战、小额广告测试 | 2～4 周起 | GDB §28.2 的数据决策 |

**合计约 4～6 个月到软启动**。其中最不可控的是 Gate B/C 的**真人测试组织**，不是代码本身。

---

# 7. 资源与成本估算（JUDGEMENT）

| 项 | 估计 | 说明 |
|---|---|---|
| 开发 | 单人 + AI | 玩法、网络、测试代码 AI 能承担大部分；关卡手感和美术验收仍需人工 |
| 美术 | 采用 §3.5 方案后：地图模块套件 + 少量 VFX + UI 图标 | 如果坚持 VB 的自制写实角色路线，工作量至少翻倍，还要外包绑定和动画 |
| 动画 | 丧尸跑/扑咬/尸变/注射/重连约 6～8 段 | Roblox 动画编辑器或 Blender 制作；可以买授权动画包 |
| 音效 | 约 15 个关键音效 | 必须记录授权（VB §10.4 manifest） |
| 测试人员 | 每周 1～2 场，每场 10～24 人 | 社区运营时间是隐性成本 |
| 推广 | Roblox 广告的小额测试预算 | 先测缩略图点击率和留存，再决定是否加大投入；具体金额按当期 Robux 价格决定 |

---

# 8. 风险登记表

| ID | 风险 | 可能性 | 影响 | 缓解 | 触发信号 |
|---|---|---|---|---|---|
| R1 | 上线初期人数不足 4 | 高 | 致命 | Bot 补位、中途加入规则、社区测试之夜 | 练习区平均等待 > 60 秒 |
| R2 | 断链很少发生（树太扁） | 中 | 高 | 根节点杠杆、相对 HUB 阈值、`tree_shape_snapshot` 埋点 | 断链参与率 < 30%（GDB §22.4） |
| R3 | 一针定胜负 | 中 | 高 | 重连距离/时长、解药数量、扫描精度 | 治愈枢纽后 30 秒内结束的局占比过高 |
| R4 | 新手看不懂断联 | 中 | 高 | §3.1 简化潜伏；HUD 引导；训练区 Bot 演示 | 问卷第 3 题理解率 < 60% |
| R5 | 手机上扑咬"明明咬到了" | 高 | 中 | §5.2 延迟补偿、`bite_near_miss` 埋点 | near-miss 比例高、手机玩家流失 |
| R6 | 潜伏或拓扑信息泄露 | 中 | 中 | §5.1 清单 + 开发者面板审计 | QA 审计失败 |
| R7 | 24 人局手机掉帧 | 中 | 中 | Avatar 配件裁剪、特效分级、流式加载 | 低端机 1% low < 20 FPS |
| R8 | 美术范围失控 | 高（如按 VB 原方案） | 中 | §3.5 Avatar 方案；Gate C 前不批量生产 | 美术工时 > 玩法工时 |
| R9 | 内容分级过高，限制可触达人群 | 低～中 | 中 | 风格化、非血腥；"扑击感染"而非写实撕咬 | 问卷结果高于预期 |
| R10 | AI 生成代码绕过服务端校验 | 中 | 高 | GDB §26.3 禁令 + CI 中的安全测试 | 安全测试失败 |

---

# 9. 需要产品负责人拍板的决策

| # | 决策 | 推荐 | 备选 |
|---|---|---|---|
| D1 | 潜伏期保密 | **P0 公开尸变过渡（3～5 秒），保密版推到实验** | 维持 GDB V1.0 完整保密 |
| D2 | 零号平衡杠杆 | **零号扑咬冷却 ×1.5 + 重连到根需 1.5 秒** | 不加杠杆，靠埋点观察 |
| D3 | 扫描分级 | **相对阈值** | 维持绝对 1 / 2～3 / 4+ |
| D4 | Bot 补位 | **开局补到 6 名参与者；有 Bot 的局不发正式奖励** | 只用于内部测试，不对玩家开放 |
| D5 | 中途加入 | **60 秒内为人类，之后为丧尸叶子，撤离期观战** | 隔离区等待下一局（GDB 原方案） |
| D6 | 角色方案 | **玩家 R15 Avatar + 感染叠加层** | 自制写实角色（VB 原方案） |
| D7 | P0 零号产生方式 | **公开的随机"隔离突破"事件**（实现最简单），NPC 推到 Gate B | NPC 先咬（GDB 原 BASELINE） |
| D8 | Gate A 验收人数 | **8 名参与者（可含 Bot）** | 4 人 |
| D9 | 首发语言 | **英文为主 + 自动翻译**，中文作为一种本地化语言 | 中英并列 |

拍板后，建议把结论分别写入 GDB V1.1（D1～D5、D7、D8）和 VB V1.1（D1、D6、D9 与 §4 不一致清单），本文随之归档。

---

# 10. 给 AI Coding Agent 的启动 Prompt 补丁

在 GDB §26.4 的启动 Prompt 末尾追加：

```text
补充约束（来自《落地可行性评估与补充 V1.1》）：
- 所有服务以 ParticipantId 而不是 Player/UserId 为键；Bot 与真人共用状态机。
- 纯逻辑放在 src/server/logic，不得引用任何 Roblox 全局对象，必须能在 Lune 中测试。
- 遵守"引擎泄密面清单"：秘密状态不得写入 Team、Attributes、Humanoid 属性、Tool、leaderstats。
- 读条交互由服务端累计计时；ProximityPrompt.Triggered 只作为意图。
- 扑咬判定使用 1 秒位置历史 + ping 回溯 + 容差，参数来自 BalanceConfig。
- 通过 Studio MCP 做的场景修改必须回写到 Rojo 管理的文件。
```

---

# 11. 参考来源（2026-10-24 核对）

- Highlight 上限提高到 255：[Lights, Camera, More Highlights!（DevForum 公告）](https://devforum.roblox.com/t/lights-camera-more-highlights/4061534)
- Server Authority 正式发布：[Full Release 公告](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)、[Roblox Newsroom 2026-07](https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority)、[官方文档](https://create.roblox.com/docs/projects/server-authority)、[角色重新挂载后回滚问题（Bug 报告）](https://devforum.roblox.com/t/server-authority-rollback-issues-after-parenting-character/4813298)
- Studio 内置 MCP：[Roblox/roblox-studio-agent-plugin](https://github.com/Roblox/roblox-studio-agent-plugin)、[Studio MCP Server Updates（DevForum）](https://devforum.roblox.com/t/studio-mcp-server-updates-and-external-llm-support-for-assistant/4415631)
- 云端测试：[Luau Execution API 文档](https://create.roblox.com/docs/cloud/reference/features/luau-execution)、[Roblox/place-ci-cd-demo](https://github.com/Roblox/place-ci-cd-demo)、[Roblox/jest-roblox](https://github.com/Roblox/jest-roblox)
- Creator Rewards：[官方公告](https://devforum.roblox.com/t/introducing-creator-rewards-earn-more-by-growing-the-community/3777628)、[官方文档](https://create.roblox.com/docs/creator-rewards)

---

# 附录 A. 感染树形状模拟脚本（Python，可复现 §3.2）

```python
import random, statistics as st

def run(N, seeds, sigma, root_is_best, infect_frac, trials=4000):
    hub_rate = 0; best_cut = []; root_child_share = []
    for _ in range(trials):
        skill = [random.lognormvariate(0, sigma) for _ in range(N)]
        order = sorted(range(N), key=lambda i: -skill[i])
        roots = order[:seeds] if root_is_best else random.sample(range(N), seeds)
        parent = {r: None for r in roots}
        humans = set(range(N)) - set(roots)
        target = int(N * infect_frac)
        while len(parent) < target and humans:
            inf = list(parent)
            biter = random.choices(inf, [skill[i] for i in inf])[0]
            v = random.choice(list(humans)); humans.remove(v); parent[v] = biter
        children = {}
        for c, p in parent.items():
            if p is not None: children.setdefault(p, []).append(c)
        def size(n): return 1 + sum(size(c) for c in children.get(n, []))
        curable = [n for n in parent if parent[n] is not None]
        m = max((size(n) for n in curable), default=0)
        best_cut.append(m / len(parent)); hub_rate += m >= 4
        rc = sum(len(children.get(r, [])) for r in roots)
        root_child_share.append(rc / max(1, len(curable)))
    return hub_rate / trials, st.mean(best_cut), st.mean(root_child_share)
```

**升级方向**（Gate 0）：加入二维地图和移动速度，模拟治愈→断联→8 秒重连的动态过程，统计"一针后 30 秒内的阵营人数变化"，用来预调 `DisconnectSeconds`、重连半径和解药数量。

---

# 版本记录

| 版本 | 日期 | 说明 |
|---|---|---|
| V1.1-draft | 2026-10-24 | 首次可行性评估：潜伏泄密、树形状模拟、冷启动与 Bot、Avatar 方案、延迟补偿、引擎泄密面、工具链、修订路线与决策清单 |

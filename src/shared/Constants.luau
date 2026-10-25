--!strict
-- 枚举常量（GDB V1.1 §4.1、§7.1、§7.5）。代码中只使用这些枚举，显示文案见 StateLabels。

local Constants = {}

Constants.PlayerState = table.freeze({
	HUMAN = "HUMAN",
	INCUBATING = "INCUBATING",
	INFECTED = "INFECTED",
	UNSTABLE = "UNSTABLE",
	EXTRACTED = "EXTRACTED",
	SPECTATOR = "SPECTATOR",
})

Constants.RoundPhase = table.freeze({
	WAITING = "WAITING",
	PREPARE = "PREPARE",
	OUTBREAK = "OUTBREAK",
	CONTEST = "CONTEST",
	EXTRACTION = "EXTRACTION",
	RESULT = "RESULT",
})

-- 公开属性键（§17.6、§20.4）。A0 中阵营与耐力本来就对所有人可见，可以放进角色/玩家属性；
-- 感染树、扫描结果等秘密信息以后也不得写进这里。
Constants.Attribute = table.freeze({
	State = "BTC_State", -- 角色 Model 上的 HUMAN / INCUBATING / INFECTED
	Stamina = "BTC_Stamina", -- 真人 Player 上的 0..1 耐力
	ParticipantId = "BTC_ParticipantId", -- 角色 Model 上的 ParticipantId，供客户端选择扑咬提示目标
	-- 以下战斗状态都是公开信息（§9A、§17.6）：动作与生命条本来就会被所有人看见。
	Combat = "BTC_Combat", -- 丧尸角色上的 ACTIVE / DOWNED / DEAD / STUNNED
	Health = "BTC_Health", -- 丧尸角色上的 0..1 生命比例
	RespawnAt = "BTC_RespawnAt", -- DEAD 时的服务端复活时刻（Workspace:GetServerTimeNow）
	Protected = "BTC_Protected", -- 复活保护 / 治愈保护公开布尔状态（§9A.3、§10.3）
	Grabbed = "BTC_Grabbed", -- 人类被擒抱（§9A.6）
	Grabbing = "BTC_Grabbing", -- 丧尸正在擒抱（§9A.6）
	-- §6.1：零号源头是公开身份（隔离突破公告），只放布尔标签，不含树关系。
	Root = "BTC_Root",
	-- §17.6 QA：开发者泄密审计开关（仅为公开布尔，不含任何对局秘密）。
	DebugLeakAudit = "BTC_DebugLeakAudit",
})

-- 客户端通过 RequestAction 只能发送这些意图（§20.4）
Constants.Action = table.freeze({
	TryBite = "TryBite",
	StartBite = "StartBite",
	SetSprint = "SetSprint",
	Fire = "Fire",
	Reload = "Reload",
	SelectWeapon = "SelectWeapon",
	StartCure = "StartCure",
	TryRelink = "TryRelink",
	StartRelay = "StartRelay",
	StartScan = "StartScan",
	StartExtract = "StartExtract",
	CancelChannel = "CancelChannel",
})

return table.freeze(Constants)

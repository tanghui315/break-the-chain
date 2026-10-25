--!strict
-- Server → Client 事件名（GDB V1.1 §20.7）。
-- Public 事件经 PublicMatchEvent 广播，只携带公开字段；Private 事件经 PrivatePlayerEvent 用 FireClient 定向发送。

local PublicEventTypes = {}

PublicEventTypes.Public = table.freeze({
	OutbreakStarted = "OutbreakStarted",
	InfectionTurning = "InfectionTurning",
	InfectionRevealed = "InfectionRevealed",
	ChainCutNearby = "ChainCutNearby",
	ExtractionOpened = "ExtractionOpened",
	RoundPhaseChanged = "RoundPhaseChanged",
	RoundResult = "RoundResult",
	-- §9A.4：手枪开火的公开噪声来源（位置已按 4 studs 取整）
	GunshotFired = "GunshotFired",
})

PublicEventTypes.Private = table.freeze({
	-- Gate A0：回合开始时告知本人 ParticipantId
	YouAre = "YouAre",
	-- Gate A0：扑咬请求的私有判定结果（命中、原因码、服务端冷却时刻）
	BiteResult = "BiteResult",
	-- Gate A0.5：开火结果、库存变更与玩家丧尸的击退冲量
	FireResult = "FireResult",
	WeaponState = "WeaponState",
	Knockback = "Knockback",
	YouAreIncubating = "YouAreIncubating",
	YouAreUnstable = "YouAreUnstable",
	ScannerResults = "ScannerResults",
	CureChannelProgress = "CureChannelProgress",
	BranchWarning = "BranchWarning",
})

return table.freeze(PublicEventTypes)
